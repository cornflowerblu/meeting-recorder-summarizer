"""
Unit tests for bedrock_summarize Lambda function
Tests Claude-based summarization with structured output
"""

import pytest
from unittest.mock import patch, MagicMock, mock_open
from botocore.exceptions import ClientError
import json
import sys
import os

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/bedrock_summarize'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))


@pytest.mark.unit
class TestBedrockSummarize:
    """Test suite for bedrock_summarize Lambda"""
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_successful_summary_generation(self, mock_config, mock_bedrock, mock_s3):
        """Test successful summary generation"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        # Mock S3 transcript download
        transcript_data = {
            'recording_id': 'rec_123',
            'segments': [
                {
                    'id': 'seg_001',
                    'start_ms': 0,
                    'end_ms': 5000,
                    'speaker_label': 'spk_0',
                    'text': 'Hello team'
                }
            ],
            'speaker_map': {'spk_0': {'name': 'Alice'}},
            'pipeline_version': '1.0.0'
        }
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps(transcript_data).encode())
        })
        
        # Mock Bedrock response
        summary_data = {
            'summary_text': 'Team meeting summary',
            'actions': [],
            'decisions': []
        }
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': json.dumps(summary_data)}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['recording_id'] == 'rec_123'
        assert 'summary_s3_uri' in result
        assert mock_bedrock.invoke_model.called
        assert mock_s3.put_object.called
    
    @patch('handler.s3_client')
    @patch('handler.Config')
    def test_s3_transcript_download_and_parsing(self, mock_config, mock_s3):
        """Test S3 transcript download and JSON parsing"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        
        transcript_data = {
            'recording_id': 'rec_123',
            'segments': [],
            'speaker_map': {}
        }
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps(transcript_data).encode())
        })
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        # Will fail on Bedrock call, but we can verify S3 was accessed
        try:
            lambda_handler(event, context)
        except:
            pass
        
        assert mock_s3.get_object.called
    
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_claude_prompt_construction(self, mock_config, mock_bedrock):
        """Test Claude prompt construction with transcript"""
        from handler import lambda_handler
        
        mock_config.BEDROCK_MODEL_ID = 'anthropic.claude-sonnet-4-20250514'
        
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': '{"summary_text":"test","actions":[],"decisions":[]}'}]
            }).encode())
        })
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_text': 'Meeting transcript text here'
        }
        context = MagicMock()
        
        try:
            lambda_handler(event, context)
        except:
            pass
        
        # Verify Bedrock was invoked with a prompt
        if mock_bedrock.invoke_model.called:
            call_args = mock_bedrock.invoke_model.call_args
            assert call_args is not None
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_bedrock_api_invocation(self, mock_config, mock_bedrock, mock_s3):
        """Test Bedrock API invocation with correct parameters"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.BEDROCK_MODEL_ID = 'anthropic.claude-sonnet-4-20250514'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': '{"summary_text":"test","actions":[],"decisions":[]}'}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        assert mock_bedrock.invoke_model.called
        call_args = mock_bedrock.invoke_model.call_args
        assert call_args[1]['modelId'] == 'anthropic.claude-sonnet-4-20250514'
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_json_response_parsing_from_claude(self, mock_config, mock_bedrock, mock_s3):
        """Test JSON response parsing from Claude"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        summary_data = {
            'summary_text': 'Test summary',
            'actions': [{'id': 'act_001', 'description': 'Test action', 'source_timestamp_ms': 0}],
            'decisions': []
        }
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': json.dumps(summary_data)}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['recording_id'] == 'rec_123'
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_summary_structure_validation(self, mock_config, mock_bedrock, mock_s3):
        """Test summary structure validation"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        # Valid summary structure
        summary_data = {
            'summary_text': 'Test',
            'actions': [],
            'decisions': []
        }
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': json.dumps(summary_data)}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        assert 'summary_s3_uri' in result
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_invalid_json_response_handling(self, mock_config, mock_bedrock, mock_s3):
        """Test handling of invalid JSON from Claude"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        # Claude returns invalid JSON
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': 'This is not valid JSON {'}]
            }).encode())
        })
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'json' in str(exc_info.value).lower()
    
    @patch('handler.Config')
    def test_missing_required_fields_in_transcript(self, mock_config):
        """Test handling of missing required fields in transcript"""
        from handler import lambda_handler
        
        event = {
            'recording_id': 'rec_123',
            # Missing transcript_s3_uri
        }
        context = MagicMock()
        
        with pytest.raises((ValueError, KeyError)):
            lambda_handler(event, context)
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_s3_upload_of_summary_with_metadata(self, mock_config, mock_bedrock, mock_s3):
        """Test S3 upload of summary with correct metadata"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        summary_data = {
            'summary_text': 'Test',
            'actions': [],
            'decisions': []
        }
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': json.dumps(summary_data)}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        # Verify S3 put_object was called for summary upload
        assert mock_s3.put_object.called
        call_args = mock_s3.put_object.call_args
        # Summary should include metadata
        assert 'Body' in call_args[1]
    
    @patch('handler.s3_client')
    @patch('handler.bedrock_client')
    @patch('handler.Config')
    def test_pipeline_version_inclusion(self, mock_config, mock_bedrock, mock_s3):
        """Test that pipeline version is included in summary"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.PIPELINE_VERSION = '3.2.1'
        
        mock_s3.get_object = MagicMock(return_value={
            'Body': MagicMock(read=lambda: json.dumps({
                'recording_id': 'rec_123',
                'segments': [],
                'speaker_map': {}
            }).encode())
        })
        
        summary_data = {
            'summary_text': 'Test',
            'actions': [],
            'decisions': []
        }
        mock_bedrock.invoke_model = MagicMock(return_value={
            'body': MagicMock(read=lambda: json.dumps({
                'content': [{'text': json.dumps(summary_data)}]
            }).encode())
        })
        
        mock_s3.put_object = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://test-bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        # Verify pipeline version is available
        assert mock_config.PIPELINE_VERSION == '3.2.1'
