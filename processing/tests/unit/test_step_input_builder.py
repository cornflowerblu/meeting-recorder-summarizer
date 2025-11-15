"""
Unit tests for Step Functions input builder.

Tests verify that the create_step_functions_input function in start_processing
Lambda properly constructs valid input payloads for the Step Functions state machine.
"""

import pytest
from datetime import datetime, timezone
from unittest.mock import patch, MagicMock, Mock
import sys
import os

# Mock boto3 before importing handler to avoid AWS credential issues
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/start_processing'))

# Mock AWS clients at module level before import
with patch('boto3.client') as mock_client, \
     patch('boto3.resource') as mock_resource, \
     patch.dict('os.environ', {
         'STATE_MACHINE_ARN': 'arn:aws:states:us-east-1:123456789012:stateMachine:test',
         'DYNAMODB_TABLE': 'test-table',
         'AWS_REGION': 'us-east-1'
     }):
    mock_client.return_value = Mock()
    mock_resource.return_value = Mock()
    # Import the function to test
    from handler import create_step_functions_input


@pytest.fixture
def sample_metadata():
    """Sample recording metadata from DynamoDB."""
    return {
        'user_id': 'user_test123',
        'recording_id': 'rec_test456',
        'chunk_count': 5,
        'total_duration_seconds': 300,
        'created_at': '2025-11-15T19:00:00Z',
        'status': 'recording'
    }


@pytest.fixture
def minimal_metadata():
    """Minimal recording metadata with only required fields."""
    return {
        'user_id': 'user_min789',
        'recording_id': 'rec_min012'
    }


@pytest.mark.unit
class TestStepInputBuilder:
    """Test suite for Step Functions input builder."""

    def test_create_basic_input_structure(self, sample_metadata):
        """Test that basic input structure is created correctly."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        # Verify required fields are present
        assert 'recording_id' in result
        assert 'user_id' in result
        assert 's3_bucket' in result
        assert 's3_prefix' in result
        assert 'chunk_count' in result
        assert 'pipeline_version' in result
        
        # Verify correct values
        assert result['recording_id'] == 'rec_test456'
        assert result['user_id'] == 'user_test123'
        assert result['s3_bucket'] == 'test-bucket'

    def test_s3_prefix_format(self, sample_metadata):
        """Test that S3 prefix is formatted correctly."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        expected_prefix = 'users/user_test123/chunks/rec_test456/'
        assert result['s3_prefix'] == expected_prefix

    def test_chunk_count_uses_uploaded_value(self, sample_metadata):
        """Test that chunk_count uses the actual uploaded count, not metadata."""
        # Metadata says 5 chunks expected, but only 3 uploaded
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=3
        )
        
        # Should use actual uploaded count
        assert result['chunk_count'] == 3
        
        # Metadata should preserve original expected count
        assert result['metadata']['original_chunk_count'] == 5

    def test_duration_included_when_present(self, sample_metadata):
        """Test that total_duration_seconds is included when present in metadata."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['total_duration_seconds'] == 300

    def test_duration_defaults_to_zero_when_missing(self, minimal_metadata):
        """Test that total_duration_seconds defaults to 0 when not in metadata."""
        result = create_step_functions_input(
            metadata=minimal_metadata,
            bucket='test-bucket',
            uploaded_chunks=3
        )
        
        assert result['total_duration_seconds'] == 0

    def test_pipeline_version_included(self, sample_metadata):
        """Test that pipeline_version is included in output."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert 'pipeline_version' in result
        assert result['pipeline_version'] == '1.0.0'

    def test_created_at_preserved_from_metadata(self, sample_metadata):
        """Test that created_at timestamp is preserved from metadata."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['created_at'] == '2025-11-15T19:00:00Z'

    def test_created_at_none_when_missing(self, minimal_metadata):
        """Test that created_at is None when not in metadata."""
        result = create_step_functions_input(
            metadata=minimal_metadata,
            bucket='test-bucket',
            uploaded_chunks=3
        )
        
        assert result['created_at'] is None

    def test_metadata_section_structure(self, sample_metadata):
        """Test that metadata section has correct structure."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert 'metadata' in result
        assert 'trigger' in result['metadata']
        assert 'original_chunk_count' in result['metadata']
        assert 'triggered_at' in result['metadata']

    def test_metadata_trigger_value(self, sample_metadata):
        """Test that trigger value is set correctly."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['metadata']['trigger'] == 's3_upload_complete'

    def test_metadata_triggered_at_timestamp(self, sample_metadata):
        """Test that triggered_at is a valid ISO timestamp."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        triggered_at = result['metadata']['triggered_at']
        
        # Should be valid ISO format
        try:
            parsed = datetime.fromisoformat(triggered_at.replace('Z', '+00:00'))
            assert parsed is not None
        except ValueError:
            pytest.fail(f"Invalid ISO timestamp: {triggered_at}")
        
        # Should end with Z (UTC)
        assert triggered_at.endswith('Z')

    def test_original_chunk_count_preserved(self, sample_metadata):
        """Test that original chunk count from metadata is preserved."""
        sample_metadata['chunk_count'] = 10
        
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=8
        )
        
        assert result['metadata']['original_chunk_count'] == 10
        assert result['chunk_count'] == 8  # Uses actual uploaded count

    def test_original_chunk_count_defaults_to_uploaded(self, minimal_metadata):
        """Test that original_chunk_count defaults to uploaded_chunks when not in metadata."""
        result = create_step_functions_input(
            metadata=minimal_metadata,
            bucket='test-bucket',
            uploaded_chunks=7
        )
        
        assert result['metadata']['original_chunk_count'] == 7
        assert result['chunk_count'] == 7

    def test_different_bucket_names(self, sample_metadata):
        """Test handling of different bucket name formats."""
        buckets = [
            'simple-bucket',
            'bucket-with-dashes',
            'bucket.with.dots',
            'bucket-123-numbers'
        ]
        
        for bucket in buckets:
            result = create_step_functions_input(
                metadata=sample_metadata,
                bucket=bucket,
                uploaded_chunks=5
            )
            assert result['s3_bucket'] == bucket

    def test_different_user_ids(self, sample_metadata):
        """Test handling of different user ID formats."""
        user_ids = [
            'user_simple123',
            'google_oauth|abc123',
            'firebase_uid_xyz789'
        ]
        
        for user_id in user_ids:
            sample_metadata['user_id'] = user_id
            result = create_step_functions_input(
                metadata=sample_metadata,
                bucket='test-bucket',
                uploaded_chunks=5
            )
            assert result['user_id'] == user_id
            assert user_id in result['s3_prefix']

    def test_different_recording_ids(self, sample_metadata):
        """Test handling of different recording ID formats."""
        recording_ids = [
            'rec_ulid01ABC123',
            'uuid-1234-5678-90ab',
            'recording_20251115'
        ]
        
        for recording_id in recording_ids:
            sample_metadata['recording_id'] = recording_id
            result = create_step_functions_input(
                metadata=sample_metadata,
                bucket='test-bucket',
                uploaded_chunks=5
            )
            assert result['recording_id'] == recording_id
            assert recording_id in result['s3_prefix']

    def test_zero_chunks_uploaded(self, sample_metadata):
        """Test handling when zero chunks are uploaded."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=0
        )
        
        assert result['chunk_count'] == 0

    def test_large_chunk_count(self, sample_metadata):
        """Test handling of large chunk counts."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=10000
        )
        
        assert result['chunk_count'] == 10000

    def test_zero_duration(self, sample_metadata):
        """Test handling when duration is zero."""
        sample_metadata['total_duration_seconds'] = 0
        
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['total_duration_seconds'] == 0

    def test_large_duration(self, sample_metadata):
        """Test handling of very long recordings."""
        # 10 hours = 36000 seconds
        sample_metadata['total_duration_seconds'] = 36000
        
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['total_duration_seconds'] == 36000

    def test_output_is_json_serializable(self, sample_metadata):
        """Test that output can be serialized to JSON."""
        import json
        
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        # Should not raise exception
        json_str = json.dumps(result)
        assert json_str is not None
        
        # Should be deserializable
        parsed = json.loads(json_str)
        assert parsed['recording_id'] == sample_metadata['recording_id']

    def test_all_required_fields_for_step_functions(self, sample_metadata):
        """Test that all fields required by Step Functions state machine are present."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        # These fields are referenced in stepfunctions.tf
        required_fields = [
            'recording_id',
            'user_id',
            's3_bucket',
            'chunk_count'
        ]
        
        for field in required_fields:
            assert field in result, f"Missing required field: {field}"

    def test_s3_prefix_trailing_slash(self, sample_metadata):
        """Test that S3 prefix always ends with trailing slash."""
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        assert result['s3_prefix'].endswith('/')

    def test_no_sensitive_data_in_output(self, sample_metadata):
        """Test that no sensitive user data is included in output."""
        # Add some sensitive-looking fields to metadata
        sample_metadata['email'] = 'user@example.com'
        sample_metadata['access_token'] = 'secret_token_123'
        sample_metadata['api_key'] = 'api_key_456'
        
        result = create_step_functions_input(
            metadata=sample_metadata,
            bucket='test-bucket',
            uploaded_chunks=5
        )
        
        # Sensitive fields should not be in output
        assert 'email' not in result
        assert 'access_token' not in result
        assert 'api_key' not in result
        
        # Only expected fields should be present
        expected_top_level = {
            'recording_id', 'user_id', 's3_bucket', 's3_prefix',
            'chunk_count', 'total_duration_seconds', 'pipeline_version',
            'created_at', 'metadata'
        }
        assert set(result.keys()) == expected_top_level
