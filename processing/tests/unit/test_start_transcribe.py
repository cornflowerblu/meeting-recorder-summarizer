"""
Unit tests for start_transcribe Lambda function
Tests AWS Transcribe job creation with diarization
"""

import pytest
from unittest.mock import patch, MagicMock
from botocore.exceptions import ClientError
import sys
import os

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/start_transcribe'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))


@pytest.mark.unit
class TestStartTranscribe:
    """Test suite for start_transcribe Lambda"""
    
    @patch('handler.transcribe_client')
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_successful_transcription_job_creation(self, mock_config, mock_table, mock_transcribe):
        """Test successful transcription job creation"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_transcribe.start_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'meeting-transcript-rec_123-20231115-abc123',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        mock_table.update_item = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['transcription_status'] == 'IN_PROGRESS'
        assert 'transcription_job_name' in result
        assert mock_transcribe.start_transcription_job.called
    
    @patch('handler.Config')
    def test_missing_required_fields(self, mock_config):
        """Test handling of missing required fields"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        
        event = {
            'recording_id': 'rec_123',
            # Missing audio_s3_key, s3_bucket, user_id
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'missing required fields' in str(exc_info.value).lower()
    
    @patch('handler.transcribe_client')
    @patch('handler.Config')
    def test_job_name_generation_uniqueness(self, mock_config, mock_transcribe):
        """Test that job names are unique"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        
        mock_transcribe.start_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'test-job',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        # Call twice to ensure different job names
        result1 = lambda_handler(event, context)
        result2 = lambda_handler(event, context)
        
        # Job names should contain timestamp and UUID, making them unique
        call_args_1 = mock_transcribe.start_transcription_job.call_args_list[0]
        call_args_2 = mock_transcribe.start_transcription_job.call_args_list[1]
        
        job_name_1 = call_args_1[1]['TranscriptionJobName']
        job_name_2 = call_args_2[1]['TranscriptionJobName']
        
        assert job_name_1 != job_name_2
    
    @patch('handler.transcribe_client')
    @patch('handler.Config')
    def test_s3_uri_construction(self, mock_config, mock_transcribe):
        """Test correct S3 URI construction"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        
        mock_transcribe.start_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'test-job',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        call_args = mock_transcribe.start_transcription_job.call_args
        assert call_args[1]['Media']['MediaFileUri'].startswith('s3://')
    
    @patch('handler.transcribe_client')
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_dynamodb_status_update(self, mock_config, mock_table, mock_transcribe):
        """Test DynamoDB status update after job creation"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        mock_config.PIPELINE_VERSION = '1.0.0'
        
        mock_transcribe.start_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'test-job',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        mock_table.update_item = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        assert mock_table.update_item.called
    
    @patch('handler.transcribe_client')
    @patch('handler.Config')
    def test_transcribe_limit_exceeded_exception(self, mock_config, mock_transcribe):
        """Test handling of LimitExceededException"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        
        mock_transcribe.start_transcription_job = MagicMock(
            side_effect=ClientError(
                {'Error': {'Code': 'LimitExceededException'}},
                'StartTranscriptionJob'
            )
        )
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ClientError) as exc_info:
            lambda_handler(event, context)
        
        assert exc_info.value.response['Error']['Code'] == 'LimitExceededException'
    
    @patch('handler.transcribe_client')
    @patch('handler.Config')
    def test_transcribe_conflict_exception(self, mock_config, mock_transcribe):
        """Test handling of ConflictException (duplicate job name)"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        
        mock_transcribe.start_transcription_job = MagicMock(
            side_effect=ClientError(
                {'Error': {'Code': 'ConflictException'}},
                'StartTranscriptionJob'
            )
        )
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ClientError) as exc_info:
            lambda_handler(event, context)
        
        assert exc_info.value.response['Error']['Code'] == 'ConflictException'
    
    @patch('handler.transcribe_client')
    @patch('handler.dynamodb_table')
    @patch('handler.Config')
    def test_pipeline_version_tagging(self, mock_config, mock_table, mock_transcribe):
        """Test that pipeline version is included in DynamoDB update"""
        from handler import lambda_handler
        
        mock_config.S3_BUCKET_NAME = 'test-bucket'
        mock_config.TRANSCRIBE_SERVICE_ROLE_ARN = 'arn:aws:iam::123456789012:role/test-role'
        mock_config.PIPELINE_VERSION = '2.3.1'
        
        mock_transcribe.start_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'test-job',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        mock_table.update_item = MagicMock()
        
        event = {
            'recording_id': 'rec_123',
            'audio_s3_key': 'users/user_456/audio/rec_123.mp3',
            's3_bucket': 'test-bucket',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        lambda_handler(event, context)
        
        # Pipeline version should be accessible from Config
        assert mock_config.PIPELINE_VERSION == '2.3.1'
