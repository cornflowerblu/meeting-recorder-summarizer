"""
Chunk Upload Handler Lambda (T028c)

Triggered by EventBridge when a chunk is uploaded to S3.
Validates the chunk, records it in DynamoDB, and checks for session completion.

Author: Claude Code
Created: 2025-11-15
"""

import os
import re
import json
import boto3
import logging
from datetime import datetime, timedelta
from typing import Dict, Any, Optional
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch AWS SDK for X-Ray tracing
patch_all()

# Setup logging
logger = logging.getLogger()
logger.setLevel(os.getenv('LOG_LEVEL', 'INFO'))

# AWS clients
dynamodb = boto3.client('dynamodb')
lambda_client = boto3.client('lambda')
s3 = boto3.client('s3')

# Environment variables
CHUNKS_TABLE = os.getenv('CHUNKS_TABLE_NAME')
MEETINGS_TABLE = os.getenv('MEETINGS_TABLE_NAME')
SESSION_COMPLETION_LAMBDA_ARN = os.getenv('SESSION_COMPLETION_LAMBDA_ARN')

# S3 key pattern: users/{userId}/chunks/{recordingId}/chunk_{index}.mp4
S3_KEY_PATTERN = r'users/(.+)/chunks/(.+)/chunk_(\d{3})\.mp4'


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Handle S3 chunk upload events from EventBridge

    Args:
        event: EventBridge event with S3 object details
        context: Lambda context

    Returns:
        Response dict with statusCode and body
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")

        # Parse S3 event details
        detail = event.get('detail', {})
        bucket_name = detail.get('bucket', {}).get('name')
        s3_key = detail.get('object', {}).get('key')
        file_size = detail.get('object', {}).get('size', 0)
        etag = detail.get('object', {}).get('etag', '')

        if not s3_key:
            logger.warning("No S3 key in event, skipping")
            return {'statusCode': 200, 'body': 'No S3 key'}

        # Parse metadata from S3 key
        chunk_metadata = parse_s3_key(s3_key)
        if not chunk_metadata:
            logger.warning(f"Invalid S3 key format: {s3_key}")
            return {'statusCode': 200, 'body': 'Invalid key format'}

        # Enrich metadata
        chunk_metadata.update({
            's3_key': s3_key,
            'bucket_name': bucket_name,
            'file_size': file_size,
            'etag': etag,
            'uploaded_at': event.get('time', datetime.utcnow().isoformat())
        })

        logger.info(f"Processing chunk: recordingId={chunk_metadata['recording_id']}, "
                   f"chunkIndex={chunk_metadata['chunk_index']}")

        # Validate chunk
        if not validate_chunk(chunk_metadata):
            logger.error(f"Chunk validation failed: {s3_key}")
            return {'statusCode': 400, 'body': 'Validation failed'}

        # Record chunk in DynamoDB
        record_chunk(chunk_metadata)

        # Trigger session completion check
        check_session_completion(chunk_metadata['recording_id'], chunk_metadata['user_id'])

        logger.info(f"Chunk processed successfully: {s3_key}")
        return {'statusCode': 200, 'body': 'Chunk processed'}

    except Exception as e:
        logger.error(f"Error processing chunk: {str(e)}", exc_info=True)
        raise


@xray_recorder.capture('parse_s3_key')
def parse_s3_key(s3_key: str) -> Optional[Dict[str, Any]]:
    """
    Parse S3 key to extract metadata

    Format: users/{userId}/chunks/{recordingId}/chunk_{index}.mp4

    Args:
        s3_key: S3 object key

    Returns:
        Dict with user_id, recording_id, chunk_index or None if invalid
    """
    match = re.match(S3_KEY_PATTERN, s3_key)
    if not match:
        return None

    user_id, recording_id, chunk_index_str = match.groups()

    return {
        'user_id': user_id,
        'recording_id': recording_id,
        'chunk_index': int(chunk_index_str)
    }


@xray_recorder.capture('validate_chunk')
def validate_chunk(metadata: Dict[str, Any]) -> bool:
    """
    Validate chunk metadata

    Args:
        metadata: Chunk metadata dict

    Returns:
        True if valid, False otherwise
    """
    # Check file size
    if metadata['file_size'] <= 0:
        logger.error(f"Invalid file size: {metadata['file_size']}")
        return False

    # Optional: Validate S3 object exists and is accessible
    try:
        s3.head_object(
            Bucket=metadata['bucket_name'],
            Key=metadata['s3_key']
        )
    except Exception as e:
        logger.error(f"S3 object not accessible: {e}")
        return False

    return True


@xray_recorder.capture('record_chunk')
def record_chunk(metadata: Dict[str, Any]) -> None:
    """
    Record chunk in DynamoDB chunks table

    Args:
        metadata: Chunk metadata dict
    """
    # Calculate TTL (30 days from now)
    ttl = int((datetime.utcnow() + timedelta(days=30)).timestamp())

    item = {
        'recordingId': {'S': metadata['recording_id']},
        'chunkIndex': {'N': str(metadata['chunk_index'])},
        'userId': {'S': metadata['user_id']},
        's3Key': {'S': metadata['s3_key']},
        'bucketName': {'S': metadata['bucket_name']},
        'fileSize': {'N': str(metadata['file_size'])},
        'etag': {'S': metadata['etag']},
        'uploadedAt': {'S': metadata['uploaded_at']},
        'status': {'S': 'validated'},
        'retryCount': {'N': '0'},
        'ttl': {'N': str(ttl)}
    }

    try:
        dynamodb.put_item(
            TableName=CHUNKS_TABLE,
            Item=item
        )
        logger.info(f"Recorded chunk in DynamoDB: {metadata['recording_id']}/chunk_{metadata['chunk_index']:03d}")
    except Exception as e:
        logger.error(f"Failed to record chunk in DynamoDB: {e}")
        raise


@xray_recorder.capture('check_session_completion')
def check_session_completion(recording_id: str, user_id: str) -> None:
    """
    Invoke Session Completion Detector Lambda

    Args:
        recording_id: Recording ID
        user_id: User ID
    """
    payload = {
        'recordingId': recording_id,
        'userId': user_id
    }

    try:
        response = lambda_client.invoke(
            FunctionName=SESSION_COMPLETION_LAMBDA_ARN,
            InvocationType='Event',  # Async invocation
            Payload=json.dumps(payload)
        )
        logger.info(f"Triggered session completion check for {recording_id}")
    except Exception as e:
        logger.warning(f"Failed to trigger session completion check: {e}")
        # Don't raise - this is a non-critical operation
