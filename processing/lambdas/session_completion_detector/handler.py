"""
Session Completion Detector Lambda (T028d)

Checks if all chunks for a recording session have been uploaded.
When complete, triggers Step Functions processing workflow.

Author: Claude Code
Created: 2025-11-15
"""

import os
import json
import boto3
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch AWS SDK for X-Ray tracing
patch_all()

# Setup logging
logger = logging.getLogger()
logger.setLevel(os.getenv('LOG_LEVEL', 'INFO'))

# AWS clients
dynamodb = boto3.client('dynamodb')
stepfunctions = boto3.client('stepfunctions')

# Environment variables
CHUNKS_TABLE = os.getenv('CHUNKS_TABLE_NAME')
MEETINGS_TABLE = os.getenv('MEETINGS_TABLE_NAME')
PROCESSING_STATE_MACHINE_ARN = os.getenv('PROCESSING_STATE_MACHINE_ARN', '')


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Check if recording session is complete and trigger processing

    Args:
        event: Event with recordingId and userId
        context: Lambda context

    Returns:
        Response dict with completion status
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")

        recording_id = event.get('recordingId')
        user_id = event.get('userId')

        if not recording_id or not user_id:
            logger.error("Missing recordingId or userId in event")
            return {'statusCode': 400, 'body': 'Missing required fields'}

        logger.info(f"Checking completion for recording: {recording_id}")

        # Get expected chunk count from catalog
        expected_chunks = get_expected_chunk_count(recording_id, user_id)

        if expected_chunks is None:
            logger.info(f"Recording {recording_id} still in progress (no expected count)")
            return {
                'statusCode': 200,
                'body': 'Recording in progress',
                'complete': False
            }

        # Count uploaded chunks
        uploaded_chunks = count_uploaded_chunks(recording_id)

        logger.info(f"Recording {recording_id}: {len(uploaded_chunks)}/{expected_chunks} chunks")

        # Check for missing chunks
        missing_indices = detect_missing_chunks(uploaded_chunks, expected_chunks)

        if missing_indices:
            logger.warning(f"Recording {recording_id} has missing chunks: {missing_indices}")
            update_session_status(recording_id, user_id, 'incomplete_chunks', {
                'missing_chunk_indices': missing_indices
            })
            return {
                'statusCode': 200,
                'body': 'Missing chunks detected',
                'complete': False,
                'missing_chunks': missing_indices
            }

        # Session is complete!
        if len(uploaded_chunks) == expected_chunks:
            logger.info(f"Recording {recording_id} complete with {expected_chunks} chunks")

            # Update status to ready for processing
            update_session_status(recording_id, user_id, 'ready_for_processing')

            # Trigger Step Functions processing workflow
            trigger_processing(recording_id, user_id, expected_chunks)

            return {
                'statusCode': 200,
                'body': 'Session complete, processing triggered',
                'complete': True,
                'chunk_count': expected_chunks
            }

        # Not yet complete
        return {
            'statusCode': 200,
            'body': 'Session not yet complete',
            'complete': False,
            'uploaded': len(uploaded_chunks),
            'expected': expected_chunks
        }

    except Exception as e:
        logger.error(f"Error checking session completion: {str(e)}", exc_info=True)
        raise


@xray_recorder.capture('get_expected_chunk_count')
def get_expected_chunk_count(recording_id: str, user_id: str) -> Optional[int]:
    """
    Get expected chunk count from catalog (meetings table)

    Args:
        recording_id: Recording ID
        user_id: User ID

    Returns:
        Expected chunk count or None if not set
    """
    try:
        response = dynamodb.get_item(
            TableName=MEETINGS_TABLE,
            Key={
                'pk': {'S': f'{user_id}#{recording_id}'},
                'sk': {'S': 'METADATA'}
            },
            ProjectionExpression='expectedChunkCount'
        )

        item = response.get('Item', {})
        if 'expectedChunkCount' in item:
            return int(item['expectedChunkCount']['N'])

        return None

    except Exception as e:
        logger.error(f"Failed to get expected chunk count: {e}")
        raise


@xray_recorder.capture('count_uploaded_chunks')
def count_uploaded_chunks(recording_id: str) -> List[int]:
    """
    Query chunks table to get all uploaded chunks for a recording

    Args:
        recording_id: Recording ID

    Returns:
        List of chunk indices that have been uploaded
    """
    try:
        uploaded_indices = []
        last_evaluated_key = None

        while True:
            query_params = {
                'TableName': CHUNKS_TABLE,
                'KeyConditionExpression': 'recordingId = :rid',
                'ExpressionAttributeValues': {
                    ':rid': {'S': recording_id}
                },
                'ProjectionExpression': 'chunkIndex, #status',
                'ExpressionAttributeNames': {
                    '#status': 'status'
                }
            }

            if last_evaluated_key:
                query_params['ExclusiveStartKey'] = last_evaluated_key

            response = dynamodb.query(**query_params)

            for item in response.get('Items', []):
                # Only count validated chunks
                if item.get('status', {}).get('S') == 'validated':
                    chunk_index = int(item['chunkIndex']['N'])
                    uploaded_indices.append(chunk_index)

            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break

        return sorted(uploaded_indices)

    except Exception as e:
        logger.error(f"Failed to count uploaded chunks: {e}")
        raise


@xray_recorder.capture('detect_missing_chunks')
def detect_missing_chunks(uploaded_indices: List[int], expected_count: int) -> List[int]:
    """
    Detect missing chunk indices

    Args:
        uploaded_indices: List of uploaded chunk indices
        expected_count: Expected total chunk count

    Returns:
        List of missing chunk indices
    """
    expected_set = set(range(expected_count))
    uploaded_set = set(uploaded_indices)
    missing = sorted(expected_set - uploaded_set)

    return missing


@xray_recorder.capture('update_session_status')
def update_session_status(recording_id: str, user_id: str, status: str,
                         metadata: Optional[Dict[str, Any]] = None) -> None:
    """
    Update session status in meetings table

    Args:
        recording_id: Recording ID
        user_id: User ID
        status: New status value
        metadata: Optional additional metadata to store
    """
    try:
        update_expression = 'SET #status = :status, updatedAt = :updated_at'
        expression_attribute_values = {
            ':status': {'S': status},
            ':updated_at': {'S': datetime.utcnow().isoformat()}
        }
        expression_attribute_names = {
            '#status': 'status'
        }

        if metadata:
            update_expression += ', statusMetadata = :metadata'
            expression_attribute_values[':metadata'] = {
                'M': {k: {'S': json.dumps(v)} for k, v in metadata.items()}
            }

        dynamodb.update_item(
            TableName=MEETINGS_TABLE,
            Key={
                'pk': {'S': f'{user_id}#{recording_id}'},
                'sk': {'S': 'METADATA'}
            },
            UpdateExpression=update_expression,
            ExpressionAttributeValues=expression_attribute_values,
            ExpressionAttributeNames=expression_attribute_names
        )

        logger.info(f"Updated session status to '{status}' for {recording_id}")

    except Exception as e:
        logger.error(f"Failed to update session status: {e}")
        raise


@xray_recorder.capture('trigger_processing')
def trigger_processing(recording_id: str, user_id: str, chunk_count: int) -> None:
    """
    Trigger Step Functions processing workflow

    Args:
        recording_id: Recording ID
        user_id: User ID
        chunk_count: Total chunk count
    """
    if not PROCESSING_STATE_MACHINE_ARN:
        logger.warning("PROCESSING_STATE_MACHINE_ARN not set, skipping Step Functions trigger")
        return

    execution_input = {
        'recordingId': recording_id,
        'userId': user_id,
        'chunkCount': chunk_count,
        'triggeredAt': datetime.utcnow().isoformat()
    }

    try:
        response = stepfunctions.start_execution(
            stateMachineArn=PROCESSING_STATE_MACHINE_ARN,
            name=f"{recording_id}_{int(datetime.utcnow().timestamp())}",
            input=json.dumps(execution_input)
        )

        execution_arn = response.get('executionArn')
        logger.info(f"Started Step Functions execution: {execution_arn}")

        # Update catalog with execution ARN
        dynamodb.update_item(
            TableName=MEETINGS_TABLE,
            Key={
                'pk': {'S': f'{user_id}#{recording_id}'},
                'sk': {'S': 'METADATA'}
            },
            UpdateExpression='SET processingExecutionArn = :arn',
            ExpressionAttributeValues={
                ':arn': {'S': execution_arn}
            }
        )

    except Exception as e:
        logger.error(f"Failed to trigger Step Functions: {e}")
        # Don't raise - update status to indicate failure
        update_session_status(recording_id, user_id, 'processing_trigger_failed', {
            'error': str(e)
        })
