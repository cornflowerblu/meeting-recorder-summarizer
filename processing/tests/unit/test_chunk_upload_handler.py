"""
Unit tests for chunk_upload_handler Lambda function
Tests chunk validation and DynamoDB record creation
"""

import pytest
from unittest.mock import patch, MagicMock, call
from datetime import datetime
import sys
import os

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/chunk_upload_handler'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))


@pytest.mark.unit
class TestChunkUploadHandler:
    """Test suite for chunk_upload_handler Lambda"""
    
    @patch('handler.dynamodb_chunks')
    @patch('handler.lambda_client')
    def test_valid_s3_key_parsing(self, mock_lambda, mock_dynamodb):
        """Test valid S3 key parsing"""
        from handler import lambda_handler
        
        mock_dynamodb.put_item = MagicMock()
        mock_lambda.invoke = MagicMock()
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'users/user_123/chunks/rec_456/chunk_001.mp4',
                    'size': 1024000
                }
            }
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['status'] == 'success'
        assert result['recording_id'] == 'rec_456'
        assert result['user_id'] == 'user_123'
        assert result['chunk_index'] == '001'
        mock_dynamodb.put_item.assert_called_once()
    
    @patch('handler.dynamodb_chunks')
    def test_invalid_s3_key_format(self, mock_dynamodb):
        """Test invalid S3 key format handling"""
        from handler import lambda_handler
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'invalid/path/format.mp4',
                    'size': 1024000
                }
            }
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'invalid s3 key' in str(exc_info.value).lower()
    
    @patch('handler.dynamodb_chunks')
    @patch('handler.lambda_client')
    def test_chunk_validation_logic(self, mock_lambda, mock_dynamodb):
        """Test chunk validation logic"""
        from handler import lambda_handler
        
        mock_dynamodb.put_item = MagicMock()
        mock_lambda.invoke = MagicMock()
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'users/user_123/chunks/rec_456/chunk_001.mp4',
                    'size': 1024000
                }
            }
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['status'] == 'success'
        assert result['chunk_valid'] is True
    
    @patch('handler.dynamodb_chunks')
    def test_invalid_file_size(self, mock_dynamodb):
        """Test handling of invalid file size (zero or negative)"""
        from handler import lambda_handler
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'users/user_123/chunks/rec_456/chunk_001.mp4',
                    'size': 0
                }
            }
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['status'] == 'failed'
        assert result['chunk_valid'] is False
    
    @patch('handler.dynamodb_chunks')
    @patch('handler.lambda_client')
    def test_dynamodb_record_creation(self, mock_lambda, mock_dynamodb):
        """Test DynamoDB record creation with correct structure"""
        from handler import lambda_handler
        
        mock_dynamodb.put_item = MagicMock()
        mock_lambda.invoke = MagicMock()
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'users/user_123/chunks/rec_456/chunk_001.mp4',
                    'size': 1024000
                }
            }
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        # Verify DynamoDB put_item was called
        assert mock_dynamodb.put_item.called
        call_args = mock_dynamodb.put_item.call_args
        assert call_args is not None
        item = call_args[1]['Item']
        assert 'chunk_id' in item
        assert 'recording_id' in item
    
    @patch('handler.dynamodb_chunks')
    @patch('handler.lambda_client')
    def test_session_completion_detector_invocation(self, mock_lambda, mock_dynamodb):
        """Test that session completion detector is invoked"""
        from handler import lambda_handler
        
        mock_dynamodb.put_item = MagicMock()
        mock_lambda.invoke = MagicMock()
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'},
                'object': {
                    'key': 'users/user_123/chunks/rec_456/chunk_001.mp4',
                    'size': 1024000
                }
            }
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        # Verify Lambda invocation for session completion check
        assert mock_lambda.invoke.called
    
    @patch('handler.dynamodb_chunks')
    def test_s3_access_failure_handling(self, mock_dynamodb):
        """Test error handling for missing bucket or key in event"""
        from handler import lambda_handler
        
        event = {
            'detail': {
                'bucket': {'name': 'test-bucket'}
                # Missing 'object' key
            }
        }
        context = MagicMock()
        
        with pytest.raises((KeyError, ValueError)):
            lambda_handler(event, context)
    
    @patch('handler.dynamodb_chunks')
    @patch('handler.lambda_client')
    def test_chunk_index_extraction(self, mock_lambda, mock_dynamodb):
        """Test correct extraction of chunk index from filename"""
        from handler import lambda_handler
        
        mock_dynamodb.put_item = MagicMock()
        mock_lambda.invoke = MagicMock()
        
        test_cases = [
            ('users/user_123/chunks/rec_456/chunk_001.mp4', '001'),
            ('users/user_123/chunks/rec_456/chunk_042.mp4', '042'),
            ('users/user_123/chunks/rec_456/chunk_999.mp4', '999'),
        ]
        
        for s3_key, expected_index in test_cases:
            event = {
                'detail': {
                    'bucket': {'name': 'test-bucket'},
                    'object': {
                        'key': s3_key,
                        'size': 1024000
                    }
                }
            }
            context = MagicMock()
            
            result = lambda_handler(event, context)
            
            assert result['chunk_index'] == expected_index
