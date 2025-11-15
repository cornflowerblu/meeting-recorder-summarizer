"""
FFmpeg video processing for AWS Fargate.

Processes meeting recording chunks by:
1. Downloading all chunks from S3
2. Concatenating into single video file
3. Extracting high-quality audio for transcription
4. Uploading processed files back to S3
5. Updating DynamoDB with processing status

Environment Variables Required:
- RECORDING_ID: Unique recording identifier
- S3_BUCKET: S3 bucket name containing chunks
- USER_ID: User identifier for S3 path organization
- CHUNK_COUNT: Expected number of chunks
- AWS_REGION: AWS region (default: us-east-1)
"""

import os
import sys
import json
import boto3
import subprocess
import tempfile
import shutil
from pathlib import Path
from typing import List, Dict, Any, Optional
from datetime import datetime, timezone
import logging

# Add shared modules to path
sys.path.insert(0, '/var/task/shared')

from config import Config
from logger import get_logger

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = get_logger(__name__)


class FFmpegProcessor:
    """
    FFmpeg-based video processing for meeting recordings.
    
    Handles concatenation of video chunks and audio extraction
    with optimized settings for transcription accuracy.
    """
    
    def __init__(self, recording_id: str, s3_bucket: str, user_id: str, chunk_count: int):
        """Initialize processor with recording metadata."""
        self.recording_id = recording_id
        self.s3_bucket = s3_bucket
        self.user_id = user_id
        self.chunk_count = chunk_count
        self.aws_region = os.getenv('AWS_REGION', 'us-east-1')
        
        # Initialize AWS clients
        self.s3_client = boto3.client('s3', region_name=self.aws_region)
        self.dynamodb = boto3.resource('dynamodb', region_name=self.aws_region)
        self.table = self.dynamodb.Table('meetings')
        
        # S3 path organization
        self.chunks_prefix = f"users/{user_id}/chunks/{recording_id}/"
        self.video_key = f"users/{user_id}/videos/{recording_id}.mp4"
        self.audio_key = f"users/{user_id}/audio/{recording_id}.wav"
        
        # Working directories
        self.work_dir = Path(tempfile.mkdtemp(prefix='ffmpeg_'))
        self.chunks_dir = self.work_dir / 'chunks'
        self.output_dir = self.work_dir / 'output'
        
        # Create working directories
        self.chunks_dir.mkdir(parents=True, exist_ok=True)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        
        logger.info(f"FFmpeg processor initialized for recording {recording_id}")
        logger.info(f"Working directory: {self.work_dir}")
    
    def update_status(self, status: str, error: Optional[str] = None) -> None:
        """Update processing status in DynamoDB."""
        try:
            pk = f"{self.user_id}#{self.recording_id}"
            
            update_expression = "SET #status = :status, updated_at = :timestamp"
            expression_values = {
                ':status': status,
                ':timestamp': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
            }
            
            if error:
                update_expression += ", error_message = :error"
                expression_values[':error'] = error
            
            if status == 'video_processing_completed':
                update_expression += (
                    ", s3_locations.video = :video_key, s3_locations.audio = :audio_key"
                )
                expression_values[':video_key'] = self.video_key
                expression_values[':audio_key'] = self.audio_key
            
            self.table.update_item(
                Key={'PK': pk, 'SK': 'METADATA'},
                UpdateExpression=update_expression,
                ExpressionAttributeNames={'#status': 'status'},
                ExpressionAttributeValues=expression_values
            )
            
            logger.info(f"Status updated to: {status}")
            
        except Exception as e:
            logger.error(f"Failed to update DynamoDB status: {e}")
            # Don't raise - status update failure shouldn't halt processing
    
    def download_chunks(self) -> List[Path]:
        """Download all video chunks from S3 to local storage."""
        logger.info(f"Downloading {self.chunk_count} chunks from S3")
        
        try:
            # List objects in chunks directory
            response = self.s3_client.list_objects_v2(
                Bucket=self.s3_bucket,
                Prefix=self.chunks_prefix
            )
            
            if 'Contents' not in response:
                raise ValueError(f"No chunks found in {self.chunks_prefix}")
            
            # Filter and sort chunk files
            chunk_objects = [
                obj for obj in response['Contents']
                if obj['Key'].endswith('.mp4') and 'chunk_' in obj['Key']
            ]
            
            if len(chunk_objects) != self.chunk_count:
                logger.warning(f"Expected {self.chunk_count} chunks, found {len(chunk_objects)}")
            
            # Sort by chunk number (chunk_001.mp4, chunk_002.mp4, etc.)
            chunk_objects.sort(key=lambda x: x['Key'])
            
            # Download each chunk
            downloaded_chunks = []
            for i, obj in enumerate(chunk_objects, 1):
                chunk_key = obj['Key']
                chunk_filename = f"chunk_{i:03d}.mp4"
                local_path = self.chunks_dir / chunk_filename
                
                logger.info(f"Downloading chunk {i}/{len(chunk_objects)}: {chunk_key}")
                
                self.s3_client.download_file(
                    Bucket=self.s3_bucket,
                    Key=chunk_key,
                    Filename=str(local_path)
                )
                
                downloaded_chunks.append(local_path)
                logger.debug(f"Downloaded to: {local_path}")
            
            logger.info(f"Successfully downloaded {len(downloaded_chunks)} chunks")
            return downloaded_chunks
            
        except Exception as e:
            error_msg = f"Failed to download chunks: {e}"
            logger.error(error_msg)
            self.update_status('failed', error_msg)
            raise
    
    def verify_chunk_integrity(self, chunks: List[Path]) -> bool:
        """Verify chunk files are valid and playable."""
        logger.info("Verifying chunk integrity with ffprobe")
        
        for chunk_path in chunks:
            try:
                # Use ffprobe to verify the chunk is a valid video file
                result = subprocess.run([
                    'ffprobe', '-v', 'quiet', '-print_format', 'json',
                    '-show_format', '-show_streams', str(chunk_path)
                ], capture_output=True, text=True, check=True)
                
                probe_data = json.loads(result.stdout)
                
                # Check for video stream
                video_streams = [
                    stream for stream in probe_data.get('streams', [])
                    if stream.get('codec_type') == 'video'
                ]
                
                if not video_streams:
                    logger.error(f"No video stream found in {chunk_path}")
                    return False
                
                # Log video properties for debugging
                video_stream = video_streams[0]
                logger.debug(f"Chunk {chunk_path.name}: {video_stream.get('width')}x{video_stream.get('height')} "
                           f"@ {video_stream.get('r_frame_rate')} fps")
                
            except subprocess.CalledProcessError as e:
                logger.error(f"ffprobe failed for {chunk_path}: {e.stderr}")
                return False
            except json.JSONDecodeError as e:
                logger.error(f"Invalid ffprobe output for {chunk_path}: {e}")
                return False
        
        logger.info("All chunks verified successfully")
        return True
    
    def create_concat_file(self, chunks: List[Path]) -> Path:
        """Create FFmpeg concat file for seamless concatenation."""
        concat_file = self.work_dir / 'concat_list.txt'
        
        with open(concat_file, 'w', encoding='utf-8') as f:
            for chunk_path in chunks:
                # Use absolute paths and escape special characters
                escaped_path = str(chunk_path).replace("'", "'\\''")
                f.write(f"file '{escaped_path}'\n")
        
        logger.info(f"Created concat file with {len(chunks)} entries")
        logger.debug(f"Concat file: {concat_file}")
        
        return concat_file
    
    def concatenate_video(self, chunks: List[Path]) -> Path:
        """Concatenate video chunks into single file using FFmpeg."""
        logger.info("Concatenating video chunks")
        
        concat_file = self.create_concat_file(chunks)
        output_video = self.output_dir / f"{self.recording_id}.mp4"
        
        # FFmpeg command for concatenation with re-encoding for consistency
        ffmpeg_cmd = [
            'ffmpeg', '-y',  # Overwrite output files
            '-f', 'concat',
            '-safe', '0',
            '-i', str(concat_file),
            '-c:v', 'libx264',  # Video codec
            '-preset', 'medium',  # Encoding speed/quality balance
            '-crf', '23',  # Constant Rate Factor (good quality)
            '-c:a', 'aac',  # Audio codec
            '-b:a', '128k',  # Audio bitrate
            '-movflags', '+faststart',  # Optimize for streaming
            str(output_video)
        ]
        
        try:
            logger.info(f"Running FFmpeg concatenation: {' '.join(ffmpeg_cmd[:10])}...")
            
            result = subprocess.run(
                ffmpeg_cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=1800  # 30 minutes timeout
            )
            
            if result.stderr:
                # FFmpeg writes progress to stderr, filter actual errors
                stderr_lines = result.stderr.split('\n')
                error_lines = [line for line in stderr_lines if 'error' in line.lower() or 'failed' in line.lower()]
                if error_lines:
                    logger.warning(f"FFmpeg warnings: {'; '.join(error_lines)}")
            
            # Verify output file exists and has reasonable size
            if not output_video.exists():
                raise FileNotFoundError("Output video file was not created")
            
            output_size = output_video.stat().st_size
            if output_size < 1024:  # Less than 1KB is suspicious
                raise ValueError(f"Output video file is too small: {output_size} bytes")
            
            logger.info(f"Video concatenation successful: {output_video} ({output_size:,} bytes)")
            return output_video
            
        except subprocess.TimeoutExpired:
            error_msg = "FFmpeg concatenation timed out after 30 minutes"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        except subprocess.CalledProcessError as e:
            error_msg = f"FFmpeg concatenation failed: {e.stderr}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
    
    def extract_audio(self, video_path: Path) -> Path:
        """Extract high-quality audio from video for transcription."""
        logger.info("Extracting audio for transcription")
        
        output_audio = self.output_dir / f"{self.recording_id}.wav"
        
        # FFmpeg command optimized for speech transcription
        # 16kHz mono WAV is optimal for AWS Transcribe
        ffmpeg_cmd = [
            'ffmpeg', '-y',  # Overwrite output files
            '-i', str(video_path),
            '-vn',  # No video
            '-acodec', 'pcm_s16le',  # Uncompressed 16-bit PCM
            '-ar', '16000',  # 16kHz sample rate (AWS Transcribe recommended)
            '-ac', '1',  # Mono audio
            '-af', 'volume=1.5,highpass=f=80,lowpass=f=8000',  # Audio filters for speech clarity
            str(output_audio)
        ]
        
        try:
            logger.info(f"Running FFmpeg audio extraction: {' '.join(ffmpeg_cmd[:8])}...")
            
            result = subprocess.run(
                ffmpeg_cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=600  # 10 minutes timeout
            )
            
            # Verify output file
            if not output_audio.exists():
                raise FileNotFoundError("Output audio file was not created")
            
            output_size = output_audio.stat().st_size
            if output_size < 1024:
                raise ValueError(f"Output audio file is too small: {output_size} bytes")
            
            logger.info(f"Audio extraction successful: {output_audio} ({output_size:,} bytes)")
            return output_audio
            
        except subprocess.TimeoutExpired:
            error_msg = "FFmpeg audio extraction timed out after 10 minutes"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
        except subprocess.CalledProcessError as e:
            error_msg = f"FFmpeg audio extraction failed: {e.stderr}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
    
    def upload_to_s3(self, local_path: Path, s3_key: str) -> None:
        """Upload processed file to S3 with metadata."""
        logger.info(f"Uploading {local_path.name} to S3: {s3_key}")
        
        try:
            file_size = local_path.stat().st_size
            
            # Upload with metadata
            extra_args = {
                'Metadata': {
                    'recording-id': self.recording_id,
                    'user-id': self.user_id,
                    'pipeline-version': Config.PIPELINE_VERSION,
                    'processed-at': datetime.now(timezone.utc).isoformat(),
                    'file-size': str(file_size)
                }
            }
            
            # Set appropriate content type
            if s3_key.endswith('.mp4'):
                extra_args['ContentType'] = 'video/mp4'
            elif s3_key.endswith('.wav'):
                extra_args['ContentType'] = 'audio/wav'
            
            self.s3_client.upload_file(
                Filename=str(local_path),
                Bucket=self.s3_bucket,
                Key=s3_key,
                ExtraArgs=extra_args
            )
            
            logger.info(f"Upload successful: s3://{self.s3_bucket}/{s3_key} ({file_size:,} bytes)")
            
        except Exception as e:
            error_msg = f"Failed to upload {s3_key}: {e}"
            logger.error(error_msg)
            raise RuntimeError(error_msg)
    
    def cleanup(self) -> None:
        """Clean up temporary files and directories."""
        try:
            if self.work_dir.exists():
                shutil.rmtree(self.work_dir)
                logger.info(f"Cleaned up working directory: {self.work_dir}")
        except Exception as e:
            logger.warning(f"Failed to cleanup working directory: {e}")
    
    def process(self) -> Dict[str, Any]:
        """
        Execute complete video processing pipeline.
        
        Returns:
            Dictionary with processing results and S3 locations
        """
        try:
            # Update status to processing
            self.update_status('video_processing')
            
            # Step 1: Download chunks
            chunks = self.download_chunks()
            
            # Step 2: Verify chunk integrity
            if not self.verify_chunk_integrity(chunks):
                raise ValueError("Chunk integrity verification failed")
            
            # Step 3: Concatenate video
            video_file = self.concatenate_video(chunks)
            
            # Step 4: Extract audio
            audio_file = self.extract_audio(video_file)
            
            # Step 5: Upload processed files
            self.upload_to_s3(video_file, self.video_key)
            self.upload_to_s3(audio_file, self.audio_key)
            
            # Step 6: Update status to completed
            self.update_status('video_processing_completed')
            
            # Return processing results
            result = {
                'recording_id': self.recording_id,
                'status': 'completed',
                'video_s3_key': self.video_key,
                'audio_s3_key': self.audio_key,
                'video_size_bytes': video_file.stat().st_size,
                'audio_size_bytes': audio_file.stat().st_size,
                'chunks_processed': len(chunks),
                'pipeline_version': Config.PIPELINE_VERSION,
                'processed_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
            }
            
            logger.info(f"Video processing completed successfully for {self.recording_id}")
            return result
            
        except Exception as e:
            error_msg = f"Video processing failed: {e}"
            logger.error(error_msg, exc_info=True)
            self.update_status('failed', error_msg)
            raise
        finally:
            self.cleanup()


def main():
    """Main entry point for Fargate task execution."""
    try:
        # Get required environment variables
        recording_id = os.getenv('RECORDING_ID')
        s3_bucket = os.getenv('S3_BUCKET')
        user_id = os.getenv('USER_ID')
        chunk_count = int(os.getenv('CHUNK_COUNT', '0'))
        
        if not all([recording_id, s3_bucket, user_id]) or chunk_count <= 0:
            raise ValueError(
                "Missing required environment variables: RECORDING_ID, S3_BUCKET, USER_ID, CHUNK_COUNT"
            )
        
        logger.info(f"Starting FFmpeg processing for recording {recording_id}")
        logger.info(f"Configuration: bucket={s3_bucket}, user={user_id}, chunks={chunk_count}")
        
        # Initialize and run processor
        processor = FFmpegProcessor(
            recording_id=recording_id,
            s3_bucket=s3_bucket,
            user_id=user_id,
            chunk_count=chunk_count
        )
        
        result = processor.process()
        
        # Output result as JSON for Step Functions
        print(json.dumps(result))
        
        logger.info("FFmpeg processing completed successfully")
        sys.exit(0)
        
    except Exception as e:
        logger.error(f"FFmpeg processing failed: {e}", exc_info=True)
        
        # Output error result as JSON
        error_result = {
            'error': 'ProcessingError',
            'message': str(e),
            'recording_id': os.getenv('RECORDING_ID', 'unknown'),
            'failed_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        }
        print(json.dumps(error_result))
        
        sys.exit(1)


if __name__ == '__main__':
    main()