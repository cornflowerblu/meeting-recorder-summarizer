"""
Check Transcribe Status Lambda
Supporting function for Step Functions workflow
"""

from typing import Dict, Any

import boto3
from botocore.exceptions import ClientError

from shared.config import Config
from shared.logger import get_logger

logger = get_logger(__name__)

# Initialize AWS client
transcribe_client = boto3.client('transcribe', region_name=Config.AWS_REGION)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Check the status of an AWS Transcribe job
    
    Args:
        event: Step Functions input with:
            - transcription_job_name: Name of transcription job to check
            - recording_id: Recording identifier
            - user_id: User identifier
            
        context: Lambda context
        
    Returns:
        Dict with updated status:
            - transcription_status: Current job status
            - transcript_uri: S3 URI of completed transcript (if completed)
            - All original event fields passed through
    """
    try:
        # Extract job name from event
        transcription_job_name = event.get('transcription_job_name')
        recording_id = event.get('recording_id')
        
        if not transcription_job_name:
            raise ValueError("Missing transcription_job_name in event")
            
        if not recording_id:
            raise ValueError("Missing recording_id in event")
        
        logger.info(
            "Checking transcription job status",
            extra={
                'recording_id': recording_id,
                'job_name': transcription_job_name
            }
        )
        
        # Get job status from Transcribe
        response = transcribe_client.get_transcription_job(
            TranscriptionJobName=transcription_job_name
        )
        
        job = response['TranscriptionJob']
        status = job['TranscriptionJobStatus']
        
        # Update event with current status
        updated_event = event.copy()
        updated_event['transcription_status'] = status
        
        if status == 'COMPLETED':
            # Extract transcript URI for downstream processing
            transcript_file_uri = job.get('Transcript', {}).get('TranscriptFileUri')
            if transcript_file_uri:
                updated_event['transcript_uri'] = transcript_file_uri
                
            logger.info(
                "Transcription job completed",
                extra={
                    'recording_id': recording_id,
                    'job_name': transcription_job_name,
                    'transcript_uri': transcript_file_uri
                }
            )
            
        elif status == 'FAILED':
            # Log failure reason
            failure_reason = job.get('FailureReason', 'Unknown failure')
            
            logger.error(
                "Transcription job failed",
                extra={
                    'recording_id': recording_id,
                    'job_name': transcription_job_name,
                    'failure_reason': failure_reason
                }
            )
            
            updated_event['failure_reason'] = failure_reason
            
        else:
            # Job still in progress
            logger.info(
                "Transcription job in progress",
                extra={
                    'recording_id': recording_id,
                    'job_name': transcription_job_name,
                    'status': status
                }
            )
        
        return updated_event
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_message = e.response['Error']['Message']
        
        logger.error(
            "AWS error checking transcription status",
            extra={
                'recording_id': event.get('recording_id'),
                'job_name': event.get('transcription_job_name'),
                'error_code': error_code,
                'error_message': error_message
            }
        )
        
        if error_code == 'BadRequestException':
            # Job not found - treat as failed
            updated_event = event.copy()
            updated_event['transcription_status'] = 'FAILED'
            updated_event['failure_reason'] = f"Job not found: {error_message}"
            return updated_event
        else:
            raise Exception(f"AWS Transcribe error: {error_message}") from e
            
    except ValueError as e:
        logger.error(
            "Input validation error",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error checking transcription status",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise