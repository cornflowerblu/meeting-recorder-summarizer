"""
Validate Input Lambda
Input validation for Step Functions AI processing pipeline
"""

from typing import Dict, Any

from shared.logger import get_logger

logger = get_logger(__name__)


class ValidationError(Exception):
    """Custom exception for validation errors"""


def lambda_handler(event: Dict[str, Any], _context: Any) -> Dict[str, Any]:
    """
    Validate input for AI processing pipeline
    
    Args:
        event: Step Functions input with recording details
        _context: Lambda context (unused)
        
    Returns:
        Validated event data
        
    Raises:
        ValidationError: If required fields are missing or invalid
    """
    try:
        # Required fields for processing
        required_fields = [
            'recording_id',
            'user_id', 
            's3_bucket',
            'chunk_count'
        ]
        
        # Check for required fields
        missing_fields = []
        for field in required_fields:
            if field not in event or not event[field]:
                missing_fields.append(field)
        
        if missing_fields:
            raise ValidationError(f"Missing required fields: {missing_fields}")
        
        # Validate chunk_count is positive integer
        try:
            chunk_count = int(event['chunk_count'])
            if chunk_count <= 0:
                raise ValueError("chunk_count must be positive")
        except (ValueError, TypeError) as e:
            raise ValidationError(f"Invalid chunk_count: {e}") from e
        
        # Validate recording_id format (should not be empty)
        recording_id = event['recording_id'].strip()
        if not recording_id:
            raise ValidationError("recording_id cannot be empty")
        
        # Validate user_id format
        user_id = event['user_id'].strip()
        if not user_id:
            raise ValidationError("user_id cannot be empty")
        
        logger.info(
            "Input validation successful",
            extra={
                'recording_id': recording_id,
                'user_id': user_id,
                'chunk_count': chunk_count
            }
        )
        
        # Return validated event data
        return event
        
    except ValidationError as ve:
        logger.error(
            "Input validation failed",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(ve)
            }
        )
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error during validation",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise