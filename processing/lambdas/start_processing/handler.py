"""
Start Processing Lambda Handler

Triggered by S3 events when the final chunk of a recording is uploaded.
Initiates the AI processing pipeline via Step Functions state machine.

Environment Variables Required:
- STATE_MACHINE_ARN: ARN of the AI processing Step Functions state machine
- DYNAMODB_TABLE: DynamoDB table name for meetings catalog
- AWS_REGION: AWS region (default: us-east-1)
"""

import json
import os
import boto3
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional
import re
import logging
from urllib.parse import unquote_plus

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
stepfunctions_client = boto3.client('stepfunctions')
dynamodb = boto3.resource('dynamodb')
s3_client = boto3.client('s3')

# Environment configuration
STATE_MACHINE_ARN = os.environ['STATE_MACHINE_ARN']
DYNAMODB_TABLE = os.environ['DYNAMODB_TABLE']
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')

table = dynamodb.Table(DYNAMODB_TABLE)


def extract_recording_info(s3_key: str) -> Optional[Dict[str, str]]:
    """
    Extract recording metadata from S3 object key.
    
    Expected format: users/{user_id}/chunks/{recording_id}/chunk_{number}.mp4
    
    Args:
        s3_key: S3 object key
        
    Returns:
        Dictionary with user_id, recording_id, and chunk_number or None if invalid
    """
    # Pattern: users/{user_id}/chunks/{recording_id}/chunk_{number}.mp4
    pattern = r'^users/([^/]+)/chunks/([^/]+)/chunk_(\d+)\.mp4$'
    match = re.match(pattern, s3_key)
    
    if not match:
        logger.warning(f"S3 key does not match expected pattern: {s3_key}")
        return None
    
    user_id, recording_id, chunk_number = match.groups()
    
    return {
        'user_id': user_id,
        'recording_id': recording_id,
        'chunk_number': chunk_number
    }


def get_recording_metadata(user_id: str, recording_id: str) -> Optional[Dict[str, Any]]:
    """
    Get recording metadata from DynamoDB.
    
    Args:
        user_id: User identifier
        recording_id: Recording identifier
        
    Returns:
        Recording metadata or None if not found
    """
    try:
        pk = f"{user_id}#{recording_id}"
        
        response = table.get_item(
            Key={'PK': pk, 'SK': 'METADATA'}
        )
        
        if 'Item' not in response:
            logger.warning(f"Recording metadata not found: {pk}")
            return None
        
        return response['Item']
        
    except Exception as e:
        logger.error(f"Failed to get recording metadata: {e}")
        return None


def count_uploaded_chunks(bucket: str, user_id: str, recording_id: str) -> int:
    """
    Count the number of chunks uploaded for a recording.
    
    Args:
        bucket: S3 bucket name
        user_id: User identifier
        recording_id: Recording identifier
        
    Returns:
        Number of uploaded chunks
    """
    try:
        prefix = f"users/{user_id}/chunks/{recording_id}/"
        
        response = s3_client.list_objects_v2(
            Bucket=bucket,
            Prefix=prefix
        )
        
        if 'Contents' not in response:
            return 0
        
        # Count files that match chunk pattern
        chunk_count = 0
        for obj in response['Contents']:
            key = obj['Key']
            if re.search(r'/chunk_\d+\.mp4$', key):
                chunk_count += 1
        
        logger.info(f"Found {chunk_count} chunks for recording {recording_id}")
        return chunk_count
        
    except Exception as e:
        logger.error(f"Failed to count chunks: {e}")
        return 0


def is_recording_complete(metadata: Dict[str, Any], uploaded_chunks: int) -> bool:
    """
    Determine if all chunks for a recording have been uploaded.
    
    Args:
        metadata: Recording metadata from DynamoDB
        uploaded_chunks: Number of chunks found in S3
        
    Returns:
        True if recording is complete and ready for processing
    """
    expected_chunks = metadata.get('chunk_count', 0)
    current_status = metadata.get('status', 'unknown')
    
    # Check if we have all expected chunks
    chunks_complete = uploaded_chunks >= expected_chunks
    
    # Check if recording is in appropriate status for processing
    valid_status = current_status in ['recording', 'pending']
    
    logger.info(f"Recording completion check: {uploaded_chunks}/{expected_chunks} chunks, "
               f"status: {current_status}, complete: {chunks_complete and valid_status}")
    
    return chunks_complete and valid_status


def update_processing_status(user_id: str, recording_id: str, execution_arn: str) -> None:
    """
    Update recording status to processing with Step Functions execution ARN.
    
    Args:
        user_id: User identifier
        recording_id: Recording identifier
        execution_arn: Step Functions execution ARN
    """
    try:
        pk = f"{user_id}#{recording_id}"
        
        table.update_item(
            Key={'PK': pk, 'SK': 'METADATA'},
            UpdateExpression=(
                "SET #status = :status, execution_arn = :arn, processing_started_at = :timestamp"
            ),
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': 'processing',
                ':arn': execution_arn,
                ':timestamp': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
            }
        )
        
        logger.info(f"Updated recording {recording_id} to processing status")
        
    except Exception as e:
        logger.error(f"Failed to update processing status: {e}")
        # Don't raise - status update failure shouldn't prevent processing


def create_step_functions_input(
    metadata: Dict[str, Any], bucket: str, uploaded_chunks: int
) -> Dict[str, Any]:
    """
    Create input payload for Step Functions state machine.
    
    Args:
        metadata: Recording metadata from DynamoDB
        bucket: S3 bucket name
        uploaded_chunks: Number of uploaded chunks
        
    Returns:
        Step Functions input payload
    """
    user_id = metadata['user_id']
    recording_id = metadata['recording_id']
    
    return {
        'recording_id': recording_id,
        'user_id': user_id,
        's3_bucket': bucket,
        's3_prefix': f"users/{user_id}/chunks/{recording_id}/",
        'chunk_count': uploaded_chunks,  # Use actual count from S3
        'total_duration_seconds': metadata.get('total_duration_seconds', 0),
        'pipeline_version': '1.0.0',  # TODO: Get from Config
        'created_at': metadata.get('created_at'),
        'metadata': {
            'trigger': 's3_upload_complete',
            'original_chunk_count': metadata.get('chunk_count', uploaded_chunks),
            'triggered_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        }
    }


def start_step_functions_execution(input_payload: Dict[str, Any]) -> str:
    """
    Start Step Functions state machine execution.
    
    Args:
        input_payload: Input data for state machine
        
    Returns:
        Execution ARN
        
    Raises:
        Exception if execution fails to start
    """
    try:
        execution_name = f"ai-processing-{input_payload['recording_id']}-{int(datetime.now().timestamp())}"
        
        response = stepfunctions_client.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=execution_name,
            input=json.dumps(input_payload)
        )
        
        execution_arn = response['executionArn']
        logger.info(f"Started Step Functions execution: {execution_arn}")
        
        return execution_arn
        
    except Exception as e:
        logger.error(f"Failed to start Step Functions execution: {e}")
        raise


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Process S3 event and conditionally start AI processing pipeline.
    
    Args:
        event: S3 event notification from EventBridge
        context: Lambda context
        
    Returns:
        Processing result with execution details
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        # Parse S3 event from EventBridge
        if 'Records' in event:
            # Direct S3 event
            s3_records = event['Records']
        elif 'detail' in event and 'object' in event['detail']:
            # EventBridge S3 event
            s3_record = {
                'eventName': event['detail']['eventName'],
                's3': {
                    'bucket': {'name': event['detail']['bucket']['name']},
                    'object': {'key': event['detail']['object']['key']}
                }
            }
            s3_records = [s3_record]
        else:
            raise ValueError("Invalid event format - expected S3 or EventBridge event")
        
        results = []
        
        for record in s3_records:
            try:
                # Extract S3 information
                bucket = record['s3']['bucket']['name']
                s3_key = unquote_plus(record['s3']['object']['key'])
                event_name = record.get('eventName', 'Unknown')
                
                logger.info(f"Processing S3 event: {event_name} for {s3_key}")
                
                # Only process chunk upload completion events
                if not event_name.startswith('ObjectCreated'):
                    logger.info(f"Ignoring non-creation event: {event_name}")
                    continue
                
                # Extract recording information from S3 key
                recording_info = extract_recording_info(s3_key)
                if not recording_info:
                    logger.info(f"Ignoring non-chunk file: {s3_key}")
                    continue
                
                user_id = recording_info['user_id']
                recording_id = recording_info['recording_id']
                chunk_number = recording_info['chunk_number']
                
                logger.info(f"Processing chunk {chunk_number} for recording {recording_id}")
                
                # Get recording metadata
                metadata = get_recording_metadata(user_id, recording_id)
                if not metadata:
                    logger.warning(f"No metadata found for recording {recording_id}, skipping")
                    continue
                
                # Count uploaded chunks
                uploaded_chunks = count_uploaded_chunks(bucket, user_id, recording_id)
                
                # Check if recording is complete and ready for processing
                if not is_recording_complete(metadata, uploaded_chunks):
                    logger.info(f"Recording {recording_id} not yet complete, waiting for more chunks")
                    results.append({
                        'recording_id': recording_id,
                        'status': 'waiting',
                        'uploaded_chunks': uploaded_chunks,
                        'expected_chunks': metadata.get('chunk_count', 0)
                    })
                    continue
                
                logger.info(f"Recording {recording_id} is complete, starting processing pipeline")
                
                # Create Step Functions input
                step_input = create_step_functions_input(metadata, bucket, uploaded_chunks)
                
                # Start Step Functions execution
                execution_arn = start_step_functions_execution(step_input)
                
                # Update recording status
                update_processing_status(user_id, recording_id, execution_arn)
                
                results.append({
                    'recording_id': recording_id,
                    'status': 'processing_started',
                    'execution_arn': execution_arn,
                    'uploaded_chunks': uploaded_chunks
                })
                
            except Exception as e:
                logger.error(f"Failed to process S3 record: {e}", exc_info=True)
                results.append({
                    'status': 'error',
                    'error': str(e),
                    's3_key': record.get('s3', {}).get('object', {}).get('key', 'unknown')
                })
        
        return {
            'statusCode': 200,
            'body': {
                'message': 'Processing completed',
                'results': results,
                'processed_records': len(s3_records)
            }
        }
        
    except Exception as e:
        logger.error(f"Lambda execution failed: {e}", exc_info=True)
        return {
            'statusCode': 500,
            'body': {
                'error': str(e),
                'message': 'Failed to process S3 event'
            }
        }
