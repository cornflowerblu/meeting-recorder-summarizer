"""
Update Catalog Lambda
Updates DynamoDB catalog with final processing results
"""

from typing import Dict, Any
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

from shared.config import Config
from shared.logger import get_logger

logger = get_logger(__name__)

# Initialize DynamoDB client
dynamodb = boto3.resource('dynamodb', region_name=Config.AWS_REGION)
table = dynamodb.Table(Config.DYNAMODB_TABLE_NAME)


def lambda_handler(event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    """
    Update DynamoDB catalog with final processing results
    
    Args:
        event: Step Functions input with processing results
        _context: Lambda context (unused)
        
    Returns:
        Updated event data
    """
    try:
        # Extract required fields
        recording_id = event.get('recording_id')
        user_id = event.get('user_id')
        
        if not recording_id or not user_id:
            raise ValueError("Missing recording_id or user_id")
        
        # Update recording status to completed
        pk = f"{user_id}#{recording_id}"
        sk = "METADATA"
        
        table.update_item(
            Key={'PK': pk, 'SK': sk},
            UpdateExpression="""
                SET #status = :status,
                    #updated_at = :updated_at,
                    #completed_at = :completed_at,
                    #pipeline_version = :pipeline_version
            """,
            ExpressionAttributeNames={
                '#status': 'status',
                '#updated_at': 'updated_at',
                '#completed_at': 'completed_at',
                '#pipeline_version': 'pipeline_version'
            },
            ExpressionAttributeValues={
                ':status': 'completed',
                ':updated_at': datetime.now().isoformat(),
                ':completed_at': datetime.now().isoformat(),
                ':pipeline_version': Config.PIPELINE_VERSION
            },
            ConditionExpression='attribute_exists(PK)'
        )
        
        logger.info(
            "Recording catalog updated successfully",
            extra={
                'recording_id': recording_id,
                'user_id': user_id,
                'status': 'completed'
            }
        )
        
        return event
        
    except ClientError as e:
        logger.error(
            "Failed to update catalog",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error updating catalog",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise
