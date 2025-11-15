"""
Start Transcribe Lambda
Implementation of T036 - AWS Transcribe job initiation with diarization
"""

import json
import uuid
from datetime import datetime
from typing import Dict, Any, Optional

import boto3
from botocore.exceptions import ClientError

from shared.config import Config
from shared.logger import get_logger

logger = get_logger(__name__)

# Initialize AWS clients
transcribe_client = boto3.client('transcribe', region_name=Config.AWS_REGION)
dynamodb = boto3.resource('dynamodb', region_name=Config.AWS_REGION)
table = dynamodb.Table(Config.DYNAMODB_TABLE_NAME)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Start Amazon Transcribe batch job with speaker diarization
    
    Args:
        event: Step Functions state input with:
            - recording_id: Unique recording identifier
            - audio_s3_key: S3 key for extracted audio file
            - s3_bucket: S3 bucket name
            - user_id: User identifier for the recording
            
        context: Lambda context
        
    Returns:
        Dict with transcription job details:
            - transcription_job_name: Unique job identifier
            - transcription_status: Job status (IN_PROGRESS)
            - recording_id: Original recording ID
            - audio_s3_key: S3 key for audio file
    """
    try:
        # Extract required fields from event
        recording_id = event.get('recording_id')
        audio_s3_key = event.get('audio_s3_key')
        s3_bucket = event.get('s3_bucket')
        user_id = event.get('user_id')
        
        # Validate input
        if not all([recording_id, audio_s3_key, s3_bucket, user_id]):
            missing_fields = [
                field for field, value in {
                    'recording_id': recording_id,
                    'audio_s3_key': audio_s3_key,
                    's3_bucket': s3_bucket,
                    'user_id': user_id
                }.items() if not value
            ]
            raise ValueError(f"Missing required fields: {missing_fields}")
        
        # Generate unique transcription job name
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        job_suffix = str(uuid.uuid4())[:8]
        transcription_job_name = (
            f"meeting-transcript-{recording_id}-{timestamp}-{job_suffix}"
        )
        
        # Construct S3 URI for audio file
        audio_s3_uri = f"s3://{s3_bucket}/{audio_s3_key}"
        
        # Define output S3 location for transcript
        transcript_s3_key = f"users/{user_id}/transcripts/{recording_id}.json"
        transcript_s3_uri = f"s3://{s3_bucket}/{transcript_s3_key}"
        
        logger.info(
            "Starting transcription job",
            extra={
                'recording_id': recording_id,
                'job_name': transcription_job_name,
                'audio_s3_uri': audio_s3_uri,
                'output_s3_uri': transcript_s3_uri
            }
        )
        
        # Start transcription job with optimized settings
        transcription_response = start_transcription_job(
            job_name=transcription_job_name,
            audio_s3_uri=audio_s3_uri,
            output_s3_uri=transcript_s3_uri,
            recording_id=recording_id
        )
        
        # Update DynamoDB with transcription job details
        update_recording_status(
            user_id=user_id,
            recording_id=recording_id,
            transcription_job_name=transcription_job_name,
            transcript_s3_key=transcript_s3_key
        )
        
        # Prepare response for Step Functions
        response = {
            'transcription_job_name': transcription_job_name,
            'transcription_status': 'IN_PROGRESS',
            'transcript_s3_key': transcript_s3_key,
            'recording_id': recording_id,
            'user_id': user_id,
            's3_bucket': s3_bucket,
            'audio_s3_key': audio_s3_key
        }
        
        logger.info(
            "Transcription job started successfully",
            extra={
                'recording_id': recording_id,
                'job_name': transcription_job_name,
                'status': 'IN_PROGRESS'
            }
        )
        
        return response
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_message = e.response['Error']['Message']
        
        logger.error(
            "AWS service error in start_transcribe",
            extra={
                'recording_id': event.get('recording_id'),
                'error_code': error_code,
                'error_message': error_message
            }
        )
        
        # Handle specific AWS errors
        if error_code == 'LimitExceededException':
            raise Exception(
                f"Transcribe service limit exceeded: {error_message}"
            )
        elif error_code == 'ConflictException':
            raise Exception(
                f"Transcription job name conflict: {error_message}"
            )
        else:
            raise Exception(f"AWS Transcribe error: {error_message}")
            
    except ValueError as e:
        logger.error(
            "Input validation error in start_transcribe",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error in start_transcribe",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise


def start_transcription_job(
    job_name: str,
    audio_s3_uri: str,
    output_s3_uri: str,
    recording_id: str
) -> Dict[str, Any]:
    """
    Start AWS Transcribe job with optimal settings for meeting recordings
    
    Args:
        job_name: Unique transcription job name
        audio_s3_uri: S3 URI for input audio file
        output_s3_uri: S3 URI for output transcript
        recording_id: Recording identifier for tracking
        
    Returns:
        Transcribe job response
    """
    # Transcription settings optimized for meeting recordings
    transcription_settings = {
        'ShowSpeakerLabels': True,
        'MaxSpeakerLabels': 10,  # Support up to 10 speakers
        'ShowAlternatives': False,  # Focus on best transcript
        'MaxAlternatives': 1
    }
    
    # Language detection settings
    language_options = ['en-US', 'es-US', 'fr-FR', 'de-DE']
    
    # Job media settings
    media_format = 'mp3'  # Consistent with FFmpeg output
    media_sample_rate_hz = 16000  # Optimal for speech recognition
    
    try:
        response = transcribe_client.start_transcription_job(
            TranscriptionJobName=job_name,
            Media={
                'MediaFileUri': audio_s3_uri
            },
            MediaFormat=media_format,
            MediaSampleRateHertz=media_sample_rate_hz,
            OutputBucketName=output_s3_uri.split('/')[2],  # Extract bucket
            OutputKey=output_s3_uri.split('/', 3)[3],      # Extract key
            Settings=transcription_settings,
            IdentifyLanguage=True,
            LanguageOptions=language_options,
            JobExecutionSettings={
                'AllowDeferredExecution': True,  # Allow queuing if busy
                'DataAccessRoleArn': Config.TRANSCRIBE_SERVICE_ROLE_ARN
            },
            Tags=[
                {
                    'Key': 'RecordingId',
                    'Value': recording_id
                },
                {
                    'Key': 'Purpose',
                    'Value': 'meeting-transcription'
                },
                {
                    'Key': 'PipelineVersion',
                    'Value': Config.PIPELINE_VERSION
                }
            ]
        )
        
        logger.info(
            "Transcribe job parameters",
            extra={
                'job_name': job_name,
                'media_format': media_format,
                'sample_rate': media_sample_rate_hz,
                'max_speakers': transcription_settings['MaxSpeakerLabels'],
                'language_detection': True,
                'recording_id': recording_id
            }
        )
        
        return response
        
    except ClientError as e:
        logger.error(
            "Failed to start transcription job",
            extra={
                'job_name': job_name,
                'audio_s3_uri': audio_s3_uri,
                'error_code': e.response['Error']['Code'],
                'error_message': e.response['Error']['Message']
            }
        )
        raise


def update_recording_status(
    user_id: str,
    recording_id: str,
    transcription_job_name: str,
    transcript_s3_key: str
) -> None:
    """
    Update DynamoDB recording entry with transcription details
    
    Args:
        user_id: User identifier
        recording_id: Recording identifier
        transcription_job_name: Transcribe job name
        transcript_s3_key: S3 key for transcript output
    """
    pk = f"{user_id}#{recording_id}"
    sk = "METADATA"
    
    try:
        table.update_item(
            Key={'PK': pk, 'SK': sk},
            UpdateExpression="""
                SET #status = :status,
                    #updated_at = :updated_at,
                    #transcription_job_name = :job_name,
                    #transcript_s3_key = :transcript_key,
                    #pipeline_version = :pipeline_version
            """,
            ExpressionAttributeNames={
                '#status': 'status',
                '#updated_at': 'updated_at',
                '#transcription_job_name': 'transcription_job_name',
                '#transcript_s3_key': 'transcript_s3_key',
                '#pipeline_version': 'pipeline_version'
            },
            ExpressionAttributeValues={
                ':status': 'transcribing',
                ':updated_at': datetime.now().isoformat(),
                ':job_name': transcription_job_name,
                ':transcript_key': transcript_s3_key,
                ':pipeline_version': Config.PIPELINE_VERSION
            },
            ConditionExpression='attribute_exists(PK)'
        )
        
        logger.info(
            "Updated recording status to transcribing",
            extra={
                'user_id': user_id,
                'recording_id': recording_id,
                'transcription_job_name': transcription_job_name
            }
        )
        
    except ClientError as e:
        if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
            logger.error(
                "Recording not found in DynamoDB",
                extra={
                    'user_id': user_id,
                    'recording_id': recording_id
                }
            )
            raise ValueError(f"Recording {recording_id} not found")
        else:
            logger.error(
                "Failed to update recording status",
                extra={
                    'user_id': user_id,
                    'recording_id': recording_id,
                    'error': str(e)
                }
            )
            raise


def get_transcription_status(job_name: str) -> Optional[str]:
    """
    Get current status of a transcription job
    
    Args:
        job_name: Transcription job name
        
    Returns:
        Job status or None if not found
    """
    try:
        response = transcribe_client.get_transcription_job(
            TranscriptionJobName=job_name
        )
        return response['TranscriptionJob']['TranscriptionJobStatus']
        
    except ClientError as e:
        if e.response['Error']['Code'] == 'BadRequestException':
            return None  # Job not found
        else:
            raise
