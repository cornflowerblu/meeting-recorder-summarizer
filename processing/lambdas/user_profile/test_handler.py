"""
Unit tests for UserProfile Lambda Handler
Handles user.signed_in events from EventBridge
"""

import json
import os
from datetime import datetime, timezone
from unittest.mock import Mock, patch, MagicMock

import pytest
from botocore.exceptions import ClientError

import handler


@pytest.fixture
def lambda_context():
    """Mock Lambda context object."""
    context = Mock()
    context.function_name = "user-profile"
    context.memory_limit_in_mb = 256
    context.invoked_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:user-profile"
    context.aws_request_id = "test-request-id"
    return context


@pytest.fixture
def valid_event():
    """Valid EventBridge user.signed_in event."""
    return {
        "version": "0",
        "id": "test-event-id",
        "detail-type": "user.signed_in",
        "source": "interview-companion.auth",
        "time": "2025-11-14T20:00:00Z",
        "detail": {
            "userId": "firebase_uid_abc123",
            "email": "user@example.com",
            "displayName": "John Doe",
            "photoURL": "https://example.com/photo.jpg",
            "provider": "google.com",
            "timestamp": "2025-11-14T20:00:00Z"
        }
    }


@pytest.fixture
def mock_dynamodb_table():
    """Mock DynamoDB table."""
    with patch('handler._get_table') as mock_get_table:
        mock_table = MagicMock()
        mock_get_table.return_value = mock_table
        yield mock_table


@pytest.fixture(autouse=True)
def set_env_vars(monkeypatch):
    """Set required environment variables for all tests."""
    monkeypatch.setenv("USERS_TABLE_NAME", "test-users-table")
    yield


class TestHappyPath:
    """Tests for successful user profile creation/update."""

    def test_create_new_user_with_all_fields(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test creating a new user profile with all fields."""
        # Arrange
        mock_dynamodb_table.get_item.return_value = {'ResponseMetadata': {}}  # No existing user
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['userId'] == 'firebase_uid_abc123'
        assert body['email'] == 'user@example.com'
        assert body['action'] == 'created'
        assert body['timestamp'] == '2025-11-14T20:00:00Z'

        # Verify DynamoDB calls
        mock_dynamodb_table.get_item.assert_called_once_with(Key={'userId': 'firebase_uid_abc123'})
        mock_dynamodb_table.put_item.assert_called_once()

        # Verify put_item payload
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['userId'] == 'firebase_uid_abc123'
        assert item['email'] == 'user@example.com'
        assert item['displayName'] == 'John Doe'
        assert item['photoURL'] == 'https://example.com/photo.jpg'
        assert item['provider'] == 'google.com'
        assert item['lastLoginDate'] == '2025-11-14T20:00:00Z'
        assert item['createdAt'] == '2025-11-14T20:00:00Z'

    def test_update_existing_user_preserves_created_at(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test updating existing user preserves createdAt timestamp."""
        # Arrange
        existing_user = {
            'Item': {
                'userId': 'firebase_uid_abc123',
                'email': 'old@example.com',
                'createdAt': '2025-01-01T00:00:00Z',
                'lastLoginDate': '2025-01-15T00:00:00Z'
            }
        }
        mock_dynamodb_table.get_item.return_value = existing_user
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['action'] == 'updated'

        # Verify createdAt was preserved
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['createdAt'] == '2025-01-01T00:00:00Z'  # Original createdAt preserved
        assert item['lastLoginDate'] == '2025-11-14T20:00:00Z'  # Updated to new login
        assert item['email'] == 'user@example.com'  # Email updated

    def test_create_user_with_minimal_fields(self, lambda_context, mock_dynamodb_table):
        """Test creating user with only required fields."""
        # Arrange
        minimal_event = {
            "detail": {
                "userId": "firebase_uid_minimal",
                "timestamp": "2025-11-14T20:00:00Z"
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(minimal_event, lambda_context)

        # Assert
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['userId'] == 'firebase_uid_minimal'
        assert body['action'] == 'created'

        # Verify only required fields in DynamoDB item
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['userId'] == 'firebase_uid_minimal'
        assert item['lastLoginDate'] == '2025-11-14T20:00:00Z'
        assert item['createdAt'] == '2025-11-14T20:00:00Z'
        assert 'email' not in item
        assert 'displayName' not in item
        assert 'photoURL' not in item
        assert 'provider' not in item


class TestInputValidation:
    """Tests for input validation logic."""

    def test_missing_user_id(self, lambda_context, mock_dynamodb_table):
        """Test error when userId is missing from event."""
        # Arrange
        event = {"detail": {"email": "user@example.com"}}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 400
        body = json.loads(response['body'])
        assert 'userId' in body['error']
        mock_dynamodb_table.get_item.assert_not_called()
        mock_dynamodb_table.put_item.assert_not_called()

    def test_empty_user_id(self, lambda_context, mock_dynamodb_table):
        """Test error when userId is empty string."""
        # Arrange
        event = {"detail": {"userId": ""}}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 400

    def test_missing_detail_object(self, lambda_context, mock_dynamodb_table):
        """Test error when detail object is missing."""
        # Arrange
        event = {"version": "0"}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 400
        mock_dynamodb_table.get_item.assert_not_called()

    def test_empty_string_fields_excluded(self, lambda_context, mock_dynamodb_table):
        """Test that empty string fields are excluded from DynamoDB item."""
        # Arrange
        event = {
            "detail": {
                "userId": "firebase_uid_123",
                "email": "",  # Empty string
                "displayName": "   ",  # Whitespace only
                "photoURL": "https://example.com/photo.jpg",
                "provider": "",  # Empty string
                "timestamp": "2025-11-14T20:00:00Z"
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 200

        # Verify empty strings excluded from item
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert 'email' not in item
        assert 'displayName' not in item
        assert 'provider' not in item
        assert item['photoURL'] == 'https://example.com/photo.jpg'  # Valid field included

    def test_whitespace_trimmed(self, lambda_context, mock_dynamodb_table):
        """Test that whitespace is trimmed from string fields."""
        # Arrange
        event = {
            "detail": {
                "userId": "firebase_uid_123",
                "email": "  user@example.com  ",
                "displayName": "  John Doe  ",
                "photoURL": "  https://example.com/photo.jpg  ",
                "provider": "  google.com  ",
                "timestamp": "2025-11-14T20:00:00Z"
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 200

        # Verify whitespace trimmed
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['email'] == 'user@example.com'
        assert item['displayName'] == 'John Doe'
        assert item['photoURL'] == 'https://example.com/photo.jpg'
        assert item['provider'] == 'google.com'

    def test_non_string_fields_excluded(self, lambda_context, mock_dynamodb_table):
        """Test that non-string optional fields are excluded."""
        # Arrange
        event = {
            "detail": {
                "userId": "firebase_uid_123",
                "email": 123,  # Not a string
                "displayName": None,  # None
                "photoURL": "https://example.com/photo.jpg",
                "provider": ["google.com"],  # List, not string
                "timestamp": "2025-11-14T20:00:00Z"
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 200

        # Verify non-strings excluded
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert 'email' not in item
        assert 'displayName' not in item
        assert 'provider' not in item
        assert item['photoURL'] == 'https://example.com/photo.jpg'


class TestTimestampHandling:
    """Tests for timestamp handling logic."""

    def test_missing_timestamp_uses_current_time(self, lambda_context, mock_dynamodb_table):
        """Test that missing timestamp defaults to current time."""
        # Arrange
        event = {
            "detail": {
                "userId": "firebase_uid_123",
                "email": "user@example.com"
                # No timestamp field
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        with patch('handler.datetime') as mock_datetime:
            mock_now = datetime(2025, 11, 14, 20, 30, 0, tzinfo=timezone.utc)
            mock_datetime.now.return_value = mock_now
            mock_datetime.timezone = timezone
            
            response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 200
        body = json.loads(response['body'])
        assert body['timestamp'] == '2025-11-14T20:30:00Z'

        # Verify timestamp in DynamoDB item
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['lastLoginDate'] == '2025-11-14T20:30:00Z'
        assert item['createdAt'] == '2025-11-14T20:30:00Z'

    def test_provided_timestamp_used(self, lambda_context, mock_dynamodb_table):
        """Test that provided timestamp is used."""
        # Arrange
        event = {
            "detail": {
                "userId": "firebase_uid_123",
                "timestamp": "2025-11-14T15:00:00Z"
            }
        }
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert response['statusCode'] == 200
        put_call_args = mock_dynamodb_table.put_item.call_args
        item = put_call_args[1]['Item']
        assert item['lastLoginDate'] == '2025-11-14T15:00:00Z'


class TestErrorHandling:
    """Tests for error handling scenarios."""

    def test_dynamodb_get_item_error(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test error handling when DynamoDB get_item fails."""
        # Arrange
        mock_dynamodb_table.get_item.side_effect = ClientError(
            {'Error': {'Code': 'ServiceUnavailable', 'Message': 'Service unavailable'}},
            'GetItem'
        )

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert response['statusCode'] == 500
        body = json.loads(response['body'])
        assert 'error' in body
        mock_dynamodb_table.put_item.assert_not_called()

    def test_dynamodb_put_item_error(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test error handling when DynamoDB put_item fails."""
        # Arrange
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.side_effect = ClientError(
            {'Error': {'Code': 'ProvisionedThroughputExceededException', 'Message': 'Throttled'}},
            'PutItem'
        )

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert response['statusCode'] == 500
        body = json.loads(response['body'])
        assert 'error' in body

    def test_unexpected_exception(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test error handling for unexpected exceptions."""
        # Arrange
        mock_dynamodb_table.get_item.side_effect = Exception("Unexpected error")

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert response['statusCode'] == 500
        body = json.loads(response['body'])
        assert 'error' in body


class TestResponseFormat:
    """Tests for response format validation."""

    def test_response_structure_on_success(self, valid_event, lambda_context, mock_dynamodb_table):
        """Test response has correct structure on success."""
        # Arrange
        mock_dynamodb_table.get_item.return_value = {}
        mock_dynamodb_table.put_item.return_value = {}

        # Act
        response = handler.handler(valid_event, lambda_context)

        # Assert
        assert isinstance(response, dict)
        assert 'statusCode' in response
        assert 'body' in response
        assert response['statusCode'] == 200

        body = json.loads(response['body'])
        assert 'userId' in body
        assert 'email' in body
        assert 'action' in body
        assert 'timestamp' in body
        assert body['action'] in ['created', 'updated']

    def test_response_structure_on_error(self, lambda_context, mock_dynamodb_table):
        """Test response has correct structure on error."""
        # Arrange
        event = {"detail": {}}  # Missing userId

        # Act
        response = handler.handler(event, lambda_context)

        # Assert
        assert isinstance(response, dict)
        assert 'statusCode' in response
        assert 'body' in response
        assert response['statusCode'] == 400

        body = json.loads(response['body'])
        assert 'error' in body
        assert isinstance(body['error'], str)
