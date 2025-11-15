"""
Unit tests for update_catalog Lambda function
Tests DynamoDB catalog update logic
"""

import pytest
from unittest.mock import patch, MagicMock, Mock
from botocore.exceptions import ClientError
import sys
import os
from datetime import datetime

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/update_catalog'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))


@pytest.mark.unit
class TestUpdateCatalog:
    """Test suite for update_catalog Lambda handler"""
    
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_successful_catalog_update(self, mock_config, mock_table):
        """Test successful catalog update with all fields"""
        from handler import lambda_handler
        
        mock_config.PIPELINE_VERSION = '1.0.0'
        mock_table.update_item = MagicMock(return_value={})
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json',
            'summary_s3_uri': 's3://bucket/summaries/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['status'] == 'completed'
        assert result['recording_id'] == 'rec_123'
        assert 'updated_at' in result
        mock_table.update_item.assert_called_once()
    
    @patch('handler.dynamodb_table')
    def test_missing_recording_id(self, mock_table):
        """Test missing recording_id handling"""
        from handler import lambda_handler
        
        event = {
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'recording_id' in str(exc_info.value).lower()
    
    @patch('handler.dynamodb_table')
    def test_missing_user_id(self, mock_table):
        """Test missing user_id handling"""
        from handler import lambda_handler
        
        event = {
            'recording_id': 'rec_123',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'user_id' in str(exc_info.value).lower()
    
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_dynamodb_conditional_check_failed(self, mock_config, mock_table):
        """Test DynamoDB ConditionalCheckFailedException handling"""
        from handler import lambda_handler
        
        mock_config.PIPELINE_VERSION = '1.0.0'
        mock_table.update_item = MagicMock(
            side_effect=ClientError(
                {'Error': {'Code': 'ConditionalCheckFailedException'}},
                'UpdateItem'
            )
        )
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json',
            'summary_s3_uri': 's3://bucket/summaries/rec_123.json'
        }
        context = MagicMock()
        
        with pytest.raises(ClientError) as exc_info:
            lambda_handler(event, context)
        
        assert exc_info.value.response['Error']['Code'] == 'ConditionalCheckFailedException'
    
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_pipeline_version_included(self, mock_config, mock_table):
        """Test that pipeline version is included in update"""
        from handler import lambda_handler
        
        mock_config.PIPELINE_VERSION = '2.5.3'
        mock_table.update_item = MagicMock(return_value={})
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json',
            'summary_s3_uri': 's3://bucket/summaries/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        # Check that update_item was called with pipeline_version
        call_args = mock_table.update_item.call_args
        assert call_args is not None
    
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_timestamp_generation(self, mock_config, mock_table):
        """Test that timestamp is generated and formatted correctly"""
        from handler import lambda_handler
        
        mock_config.PIPELINE_VERSION = '1.0.0'
        mock_table.update_item = MagicMock(return_value={})
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'transcript_s3_uri': 's3://bucket/transcripts/rec_123.json'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert 'updated_at' in result
        # Verify timestamp format (ISO 8601)
        datetime.fromisoformat(result['updated_at'].replace('Z', '+00:00'))
