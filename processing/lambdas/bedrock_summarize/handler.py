"""
Bedrock Summarization Lambda
Implementation of T037 - Claude-based meeting summarization with structured output
"""

import json
import uuid
from typing import Dict, Any
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

from shared.config import Config
from shared.logger import get_logger

logger = get_logger(__name__)

# Initialize AWS clients
bedrock_client = boto3.client('bedrock-runtime', region_name=Config.AWS_REGION)
s3_client = boto3.client('s3', region_name=Config.AWS_REGION)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Generate structured meeting summary using Claude via Amazon Bedrock
    
    Args:
        event: Step Functions input with:
            - recording_id: Unique recording identifier
            - transcript_uri: S3 URI of transcript JSON
            - user_id: User identifier
            - s3_bucket: S3 bucket name
            
        context: Lambda context
        
    Returns:
        Dict with summary details:
            - summary_s3_key: S3 key for generated summary
            - recording_id: Original recording ID
    """
    try:
        # Extract required fields
        recording_id = event.get('recording_id')
        transcript_uri = event.get('transcript_uri')
        user_id = event.get('user_id')
        s3_bucket = event.get('s3_bucket')
        
        # Validate input
        if not all([recording_id, transcript_uri, user_id, s3_bucket]):
            missing_fields = [
                field for field, value in {
                    'recording_id': recording_id,
                    'transcript_uri': transcript_uri,
                    'user_id': user_id,
                    's3_bucket': s3_bucket
                }.items() if not value
            ]
            raise ValueError(f"Missing required fields: {missing_fields}")
        
        # Extract S3 key from transcript URI
        transcript_s3_key = extract_s3_key_from_uri(transcript_uri)
        
        logger.info(
            "Starting summary generation",
            extra={
                'recording_id': recording_id,
                'transcript_s3_key': transcript_s3_key
            }
        )
        
        # Download and parse transcript
        transcript_data = download_transcript(s3_bucket, transcript_s3_key)
        
        # Generate summary using Claude
        summary_data = generate_summary_with_claude(
            transcript_data, recording_id
        )
        
        # Upload summary to S3
        summary_s3_key = f"users/{user_id}/summaries/{recording_id}.json"
        upload_summary_to_s3(
            s3_bucket, summary_s3_key, summary_data
        )
        
        # Prepare response
        response = event.copy()
        response['summary_s3_key'] = summary_s3_key
        
        logger.info(
            "Summary generation completed",
            extra={
                'recording_id': recording_id,
                'summary_s3_key': summary_s3_key,
                'actions_count': len(summary_data.get('actions', [])),
                'decisions_count': len(summary_data.get('decisions', []))
            }
        )
        
        return response
        
    except ClientError as e:
        error_code = e.response['Error']['Code']
        error_message = e.response['Error']['Message']
        
        logger.error(
            "AWS service error in bedrock_summarize",
            extra={
                'recording_id': event.get('recording_id'),
                'error_code': error_code,
                'error_message': error_message
            }
        )
        
        if error_code in ['ThrottlingException', 'ModelNotReadyException']:
            raise Exception(f"Bedrock service error: {error_message}")
        else:
            raise Exception(f"AWS error: {error_message}")
            
    except ValueError as e:
        logger.error(
            "Input validation error in bedrock_summarize",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error in bedrock_summarize",
            extra={
                'recording_id': event.get('recording_id'),
                'error': str(e)
            }
        )
        raise


def extract_s3_key_from_uri(s3_uri: str) -> str:
    """
    Extract S3 key from S3 URI
    
    Args:
        s3_uri: S3 URI like s3://bucket/key/path
        
    Returns:
        S3 key path
    """
    if not s3_uri.startswith('s3://'):
        raise ValueError(f"Invalid S3 URI format: {s3_uri}")
    
    # Remove s3:// prefix and split on first /
    parts = s3_uri[5:].split('/', 1)
    if len(parts) != 2:
        raise ValueError(f"Invalid S3 URI format: {s3_uri}")
    
    return parts[1]  # Return key part


def download_transcript(bucket: str, s3_key: str) -> Dict[str, Any]:
    """
    Download and parse transcript from S3
    
    Args:
        bucket: S3 bucket name
        s3_key: S3 key for transcript JSON
        
    Returns:
        Parsed transcript data
    """
    try:
        response = s3_client.get_object(Bucket=bucket, Key=s3_key)
        transcript_json = response['Body'].read().decode('utf-8')
        transcript_data = json.loads(transcript_json)
        
        logger.info(
            "Transcript downloaded successfully",
            extra={
                'bucket': bucket,
                'key': s3_key,
                'transcript_size': len(transcript_json)
            }
        )
        
        return transcript_data
        
    except ClientError as e:
        logger.error(
            "Failed to download transcript",
            extra={
                'bucket': bucket,
                'key': s3_key,
                'error': str(e)
            }
        )
        raise
    except json.JSONDecodeError as e:
        logger.error(
            "Failed to parse transcript JSON",
            extra={
                'bucket': bucket,
                'key': s3_key,
                'error': str(e)
            }
        )
        raise


def generate_summary_with_claude(
    transcript_data: Dict[str, Any],
    recording_id: str
) -> Dict[str, Any]:
    """
    Generate structured summary using Claude via Bedrock
    
    Args:
        transcript_data: AWS Transcribe output data
        recording_id: Recording identifier
        
    Returns:
        Structured summary data
    """
    # Extract transcript text from AWS Transcribe format
    transcript_text = extract_transcript_text(transcript_data)
    
    # Build prompt for Claude
    prompt = build_summarization_prompt(transcript_text)
    
    # Call Bedrock with Claude
    try:
        response = bedrock_client.invoke_model(
            modelId=Config.BEDROCK_MODEL_ID,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": Config.BEDROCK_MAX_TOKENS,
                "temperature": 0.1,  # Low temperature for consistent output
                "messages": [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            }),
            contentType="application/json",
            accept="application/json"
        )
        
        # Parse Claude response
        response_body = json.loads(response['body'].read())
        claude_text = response_body['content'][0]['text']
        
        # Parse structured output from Claude
        summary_data = parse_claude_response(claude_text, recording_id)
        
        logger.info(
            "Claude summary generated",
            extra={
                'recording_id': recording_id,
                'model_id': Config.BEDROCK_MODEL_ID,
                'response_length': len(claude_text)
            }
        )
        
        return summary_data
        
    except ClientError as e:
        logger.error(
            "Bedrock API error",
            extra={
                'recording_id': recording_id,
                'model_id': Config.BEDROCK_MODEL_ID,
                'error': str(e)
            }
        )
        raise
    except (json.JSONDecodeError, KeyError) as e:
        logger.error(
            "Failed to parse Bedrock response",
            extra={
                'recording_id': recording_id,
                'error': str(e)
            }
        )
        raise


def extract_transcript_text(transcript_data: Dict[str, Any]) -> str:
    """
    Extract plain text from AWS Transcribe output
    
    Args:
        transcript_data: AWS Transcribe JSON output
        
    Returns:
        Plain text transcript
    """
    try:
        # AWS Transcribe format has results.transcripts[0].transcript
        return transcript_data['results']['transcripts'][0]['transcript']
    except (KeyError, IndexError) as e:
        logger.error(
            "Invalid transcript format",
            extra={'error': str(e)}
        )
        raise ValueError(f"Invalid transcript format: {e}")


def build_summarization_prompt(transcript_text: str) -> str:
    """
    Build prompt for Claude summarization
    
    Args:
        transcript_text: Raw transcript text
        
    Returns:
        Formatted prompt for Claude
    """
    return f"""
Please analyze the following meeting transcript and provide a structured summary in JSON format.

Meeting Transcript:
{transcript_text}

Please provide your response as a JSON object with exactly this structure:

{{
  "summary_text": "A concise 2-3 paragraph summary of the meeting",
  "actions": [
    {{
      "id": "act_001",
      "description": "Clear, actionable task description",
      "owner": "Person responsible (if mentioned)",
      "source_timestamp_ms": 0
    }}
  ],
  "decisions": [
    {{
      "id": "dec_001", 
      "decision": "Clear statement of what was decided",
      "source_timestamp_ms": 0
    }}
  ],
  "key_topics": ["topic1", "topic2", "topic3"],
  "participants": ["participant1", "participant2"]
}}

Requirements:
- Extract only explicit action items that were actually discussed
- Include only clear decisions that were made during the meeting
- Use unique IDs for actions (act_001, act_002, etc.) and decisions (dec_001, dec_002, etc.)
- Set source_timestamp_ms to 0 (timestamp extraction not implemented yet)
- List key topics covered in the meeting
- Identify participants mentioned by name
- Keep the summary concise and professional
- Return only valid JSON, no additional text or formatting
"""


def parse_claude_response(
    claude_text: str,
    recording_id: str
) -> Dict[str, Any]:
    """
    Parse Claude's JSON response and add metadata
    
    Args:
        claude_text: Raw text response from Claude
        recording_id: Recording identifier
        
    Returns:
        Structured summary data with metadata
    """
    try:
        # Parse JSON response from Claude
        summary_data = json.loads(claude_text.strip())
        
        # Add required metadata
        summary_data.update({
            "recording_id": recording_id,
            "pipeline_version": Config.PIPELINE_VERSION,
            "model_version": Config.BEDROCK_MODEL_ID,
            "generated_at": datetime.now().isoformat(),
            "generation_id": str(uuid.uuid4())
        })
        
        # Validate structure
        validate_summary_structure(summary_data)
        
        return summary_data
        
    except json.JSONDecodeError as e:
        logger.error(
            "Claude returned invalid JSON",
            extra={
                'recording_id': recording_id,
                'claude_response_preview': claude_text[:500],  # First 500 chars
                'claude_response_full': claude_text,
                'claude_response_length': len(claude_text),
                'error': str(e),
                'json_error_lineno': getattr(e, 'lineno', None),
                'json_error_colno': getattr(e, 'colno', None),
                'json_error_pos': getattr(e, 'pos', None)
            }
        )
        raise ValueError(f"Invalid JSON from Claude: {e}")


def validate_summary_structure(summary_data: Dict[str, Any]) -> None:
    """
    Validate summary data structure
    
    Args:
        summary_data: Summary data to validate
        
    Raises:
        ValueError: If structure is invalid
    """
    required_fields = [
        'summary_text', 'actions', 'decisions', 'recording_id'
    ]
    
    for field in required_fields:
        if field not in summary_data:
            raise ValueError(f"Missing required field: {field}")
    
    # Validate actions structure
    for action in summary_data['actions']:
        if not isinstance(action, dict) or 'id' not in action or 'description' not in action:
            raise ValueError("Invalid action structure")
    
    # Validate decisions structure  
    for decision in summary_data['decisions']:
        if not isinstance(decision, dict) or 'id' not in decision or 'decision' not in decision:
            raise ValueError("Invalid decision structure")


def upload_summary_to_s3(
    bucket: str,
    s3_key: str,
    summary_data: Dict[str, Any]
) -> None:
    """
    Upload summary data to S3
    
    Args:
        bucket: S3 bucket name
        s3_key: S3 key for summary
        summary_data: Summary data to upload
    """
    try:
        # Convert to JSON string
        summary_json = json.dumps(summary_data, indent=2, ensure_ascii=False)
        
        # Upload to S3
        s3_client.put_object(
            Bucket=bucket,
            Key=s3_key,
            Body=summary_json,
            ContentType='application/json',
            Metadata={
                'pipeline-version': Config.PIPELINE_VERSION,
                'model-version': Config.BEDROCK_MODEL_ID,
                'recording-id': summary_data['recording_id']
            }
        )
        
        logger.info(
            "Summary uploaded to S3",
            extra={
                'bucket': bucket,
                'key': s3_key,
                'recording_id': summary_data['recording_id'],
                'summary_size': len(summary_json)
            }
        )
        
    except ClientError as e:
        logger.error(
            "Failed to upload summary to S3",
            extra={
                'bucket': bucket,
                'key': s3_key,
                'error': str(e)
            }
        )
        raise
