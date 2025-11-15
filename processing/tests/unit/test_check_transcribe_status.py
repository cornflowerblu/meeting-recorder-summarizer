"""
Unit tests for check_transcribe_status Lambda function
Tests AWS Transcribe job status checking logic
"""

import pytest
from unittest.mock import patch, MagicMock
from botocore.exceptions import ClientError
import sys
import os

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/check_transcribe_status'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))


@pytest.mark.unit
class TestCheckTranscribeStatus:
    """Test suite for check_transcribe_status Lambda handler"""
    
    @patch('handler.transcribe_client')
    def test_completed_status_with_transcript_uri(self, mock_transcribe):
        """Test COMPLETED status handling with transcript URI"""
        from handler import lambda_handler
        
        mock_transcribe.get_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'job_123',
                'TranscriptionJobStatus': 'COMPLETED',
                'Transcript': {
                    'TranscriptFileUri': 's3://bucket/transcripts/rec_123.json'
                }
            }
        })
        
        event = {
            'transcription_job_name': 'job_123',
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['transcription_status'] == 'COMPLETED'
        assert result['transcript_s3_uri'] == 's3://bucket/transcripts/rec_123.json'
        assert result['recording_id'] == 'rec_123'
    
    @patch('handler.transcribe_client')
    def test_in_progress_status(self, mock_transcribe):
        """Test IN_PROGRESS status handling"""
        from handler import lambda_handler
        
        mock_transcribe.get_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'job_123',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        event = {
            'transcription_job_name': 'job_123',
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['transcription_status'] == 'IN_PROGRESS'
        assert result['recording_id'] == 'rec_123'
        assert 'transcript_s3_uri' not in result
    
    @patch('handler.transcribe_client')
    def test_failed_status_with_reason(self, mock_transcribe):
        """Test FAILED status with failure reason"""
        from handler import lambda_handler
        
        mock_transcribe.get_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'job_123',
                'TranscriptionJobStatus': 'FAILED',
                'FailureReason': 'Invalid audio format'
            }
        })
        
        event = {
            'transcription_job_name': 'job_123',
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['transcription_status'] == 'FAILED'
        assert result['failure_reason'] == 'Invalid audio format'
    
    @patch('handler.transcribe_client')
    def test_job_not_found(self, mock_transcribe):
        """Test BadRequestException handling (job not found)"""
        from handler import lambda_handler
        
        mock_transcribe.get_transcription_job = MagicMock(
            side_effect=ClientError(
                {'Error': {'Code': 'BadRequestException', 'Message': 'Job not found'}},
                'GetTranscriptionJob'
            )
        )
        
        event = {
            'transcription_job_name': 'job_123',
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ClientError) as exc_info:
            lambda_handler(event, context)
        
        assert exc_info.value.response['Error']['Code'] == 'BadRequestException'
    
    @patch('handler.transcribe_client')
    def test_missing_transcription_job_name(self, mock_transcribe):
        """Test missing transcription_job_name handling"""
        from handler import lambda_handler
        
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'transcription_job_name' in str(exc_info.value).lower()
    
    @patch('handler.transcribe_client')
    def test_missing_recording_id(self, mock_transcribe):
        """Test missing recording_id handling"""
        from handler import lambda_handler
        
        event = {
            'transcription_job_name': 'job_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'recording_id' in str(exc_info.value).lower()
    
    @patch('handler.transcribe_client')
    def test_event_pass_through_of_original_fields(self, mock_transcribe):
        """Test that all original event fields are passed through"""
        from handler import lambda_handler
        
        mock_transcribe.get_transcription_job = MagicMock(return_value={
            'TranscriptionJob': {
                'TranscriptionJobName': 'job_123',
                'TranscriptionJobStatus': 'IN_PROGRESS'
            }
        })
        
        event = {
            'transcription_job_name': 'job_123',
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'custom_field': 'custom_value',
            'chunk_count': 5
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        # Original fields should be preserved
        assert result['recording_id'] == 'rec_123'
        assert result['user_id'] == 'user_456'
        assert result['custom_field'] == 'custom_value'
        assert result['chunk_count'] == 5
