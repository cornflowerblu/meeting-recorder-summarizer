"""
Unit tests for Firebase to AWS STS credentials exchange Lambda
MR-17 (T010)
"""

import json
import os
from datetime import datetime, timezone
from unittest.mock import Mock, patch

import pytest
from botocore.exceptions import ClientError

import handler


@pytest.fixture
def lambda_context():
    """Mock Lambda context object."""
    context = Mock()
    context.function_name = "auth-exchange"
    context.memory_limit_in_mb = 128
    context.invoked_function_arn = "arn:aws:lambda:us-east-1:123456789012:function:auth-exchange"
    context.aws_request_id = "test-request-id"
    return context


@pytest.fixture
def valid_event():
    """Valid Lambda event with proper structure."""
    return {
        "body": json.dumps({
            "id_token": "valid_firebase_token_" + "x" * 100,
            "session_name": "firebase_user_12345"
        })
    }


@pytest.fixture
def mock_sts_response():
    """Mock successful STS AssumeRoleWithWebIdentity response."""
    return {
        "Credentials": {
            "AccessKeyId": "ASIATESTACCESSKEY",
            "SecretAccessKey": "test/secret/access/key",
            "SessionToken": "test_session_token",
            "Expiration": datetime(2025, 11, 12, 19, 0, 0, tzinfo=timezone.utc),
        },
        "AssumedRoleUser": {
            "AssumedRoleId": "AROATESTROLEID:firebase_user_12345",
            "Arn": "arn:aws:sts::123456789012:assumed-role/MacOSAppRole/firebase_user_12345",
        },
    }


@pytest.fixture(autouse=True)
def set_env_vars(monkeypatch):
    """Set required environment variables for all tests."""
    monkeypatch.setenv("MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    monkeypatch.setenv("SESSION_DURATION", "3600")
    yield


class TestHappyPath:
    """Tests for successful token exchange."""

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_successful_token_exchange(self, mock_sts, valid_event, lambda_context, mock_sts_response):
        """Test successful Firebase token to AWS credentials exchange."""
        # Arrange
        mock_sts.assume_role_with_web_identity.return_value = mock_sts_response

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 200
        assert "body" in response

        body = json.loads(response["body"])
        assert "credentials" in body
        assert "assumed_role_user" in body

        # Verify credentials structure
        creds = body["credentials"]
        assert creds["AccessKeyId"] == "ASIATESTACCESSKEY"
        assert creds["SecretAccessKey"] == "test/secret/access/key"
        assert creds["SessionToken"] == "test_session_token"
        assert "Expiration" in creds

        # Verify assumed role user
        assumed_role = body["assumed_role_user"]
        assert "AROATESTROLEID" in assumed_role["AssumedRoleId"]
        assert "firebase_user_12345" in assumed_role["Arn"]

        # Verify STS was called correctly
        mock_sts.assume_role_with_web_identity.assert_called_once()
        call_args = mock_sts.assume_role_with_web_identity.call_args[1]
        assert call_args["RoleArn"] == "arn:aws:iam::123456789012:role/MacOSAppRole"
        assert call_args["RoleSessionName"] == "firebase_user_12345"
        assert call_args["DurationSeconds"] == 3600

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_body_as_dict(self, mock_sts, lambda_context, mock_sts_response):
        """Test handler works when body is already a dict (not a JSON string)."""
        # Arrange
        event = {
            "body": {
                "id_token": "valid_firebase_token_" + "x" * 100,
                "session_name": "firebase_user_12345"
            }
        }
        mock_sts.assume_role_with_web_identity.return_value = mock_sts_response

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 200


class TestInputValidation:
    """Tests for input validation logic."""

    def test_missing_id_token(self, lambda_context):
        """Test error when id_token is missing."""
        # Arrange
        event = {
            "body": json.dumps({
                "session_name": "firebase_user_12345"
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "id_token" in body["error"]

    def test_id_token_not_string(self, lambda_context):
        """Test error when id_token is not a string."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": 12345,
                "session_name": "firebase_user_12345"
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "must be a string" in body["error"]

    def test_id_token_too_large(self, lambda_context):
        """Test error when id_token exceeds maximum length."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "x" * 5000,  # Exceeds 4096 character limit
                "session_name": "firebase_user_12345"
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "token too large" in body["error"]

    def test_id_token_too_short(self, lambda_context):
        """Test error when id_token is too short."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "short",  # Less than 10 characters
                "session_name": "firebase_user_12345"
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "token too short" in body["error"]

    def test_missing_session_name(self, lambda_context):
        """Test error when session_name is missing."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "valid_firebase_token_" + "x" * 100
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "session_name" in body["error"]

    def test_session_name_not_string(self, lambda_context):
        """Test error when session_name is not a string."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "valid_firebase_token_" + "x" * 100,
                "session_name": 12345
            })
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "must be a string" in body["error"]

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_session_name_sanitization(self, mock_sts, lambda_context, mock_sts_response):
        """Test that session_name is properly sanitized."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "valid_firebase_token_" + "x" * 100,
                "session_name": "user<script>alert('xss')</script>@example.com"
            })
        }
        mock_sts.assume_role_with_web_identity.return_value = mock_sts_response

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 200

        # Verify the session name was sanitized
        call_args = mock_sts.assume_role_with_web_identity.call_args[1]
        session_name = call_args["RoleSessionName"]

        # Should not contain dangerous HTML/XSS characters
        assert "<" not in session_name
        assert ">" not in session_name
        assert "(" not in session_name
        assert ")" not in session_name
        assert "'" not in session_name

        # Should contain valid characters (@ is allowed, dangerous chars replaced with _)
        assert "@example.com" in session_name
        # The word "script" without tags is harmless, but tags are removed
        assert "user_" in session_name  # Verify substitution happened

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_session_name_truncation(self, mock_sts, lambda_context, mock_sts_response):
        """Test that session_name is truncated to 64 characters."""
        # Arrange
        event = {
            "body": json.dumps({
                "id_token": "valid_firebase_token_" + "x" * 100,
                "session_name": "a" * 100  # Exceeds 64 character limit
            })
        }
        mock_sts.assume_role_with_web_identity.return_value = mock_sts_response

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 200

        # Verify the session name was truncated
        call_args = mock_sts.assume_role_with_web_identity.call_args[1]
        session_name = call_args["RoleSessionName"]
        assert len(session_name) <= 64


class TestJSONErrorHandling:
    """Tests for JSON parsing error handling."""

    def test_malformed_json(self, lambda_context):
        """Test error when request body contains malformed JSON."""
        # Arrange
        event = {
            "body": "{invalid json: missing quotes}"
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "Invalid JSON" in body["error"]

    def test_empty_body(self, lambda_context):
        """Test error when request body is empty."""
        # Arrange
        event = {
            "body": ""
        }

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "Invalid JSON" in body["error"]

    def test_missing_body(self, lambda_context):
        """Test error when body field is missing from event."""
        # Arrange
        event = {}

        # Act
        response = handler.lambda_handler(event, lambda_context)

        # Assert
        assert response["statusCode"] == 400
        body = json.loads(response["body"])
        assert "id_token" in body["error"]  # Will fail validation for missing id_token


class TestSTSErrorScenarios:
    """Tests for AWS STS error scenarios."""

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_invalid_identity_token(self, mock_sts, valid_event, lambda_context):
        """Test error when Firebase token is invalid."""
        # Arrange
        mock_sts.assume_role_with_web_identity.side_effect = ClientError(
            {
                "Error": {
                    "Code": "InvalidIdentityToken",
                    "Message": "Invalid identity token"
                }
            },
            "AssumeRoleWithWebIdentity"
        )

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert "Invalid Firebase ID token" in body["error"]

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_expired_token(self, mock_sts, valid_event, lambda_context):
        """Test error when Firebase token has expired."""
        # Arrange
        mock_sts.assume_role_with_web_identity.side_effect = ClientError(
            {
                "Error": {
                    "Code": "ExpiredTokenException",
                    "Message": "Token has expired"
                }
            },
            "AssumeRoleWithWebIdentity"
        )

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 401
        body = json.loads(response["body"])
        assert "expired" in body["error"].lower()

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_access_denied(self, mock_sts, valid_event, lambda_context):
        """Test error when access is denied to assume role."""
        # Arrange
        mock_sts.assume_role_with_web_identity.side_effect = ClientError(
            {
                "Error": {
                    "Code": "AccessDenied",
                    "Message": "Access denied"
                }
            },
            "AssumeRoleWithWebIdentity"
        )

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 403
        body = json.loads(response["body"])
        assert "Access denied" in body["error"]

    @patch("handler.MACOS_APP_ROLE_ARN", "arn:aws:iam::123456789012:role/MacOSAppRole")
    @patch("handler.sts_client")
    def test_generic_sts_error(self, mock_sts, valid_event, lambda_context):
        """Test error handling for unknown STS errors."""
        # Arrange
        mock_sts.assume_role_with_web_identity.side_effect = ClientError(
            {
                "Error": {
                    "Code": "ServiceUnavailable",
                    "Message": "Service temporarily unavailable"
                }
            },
            "AssumeRoleWithWebIdentity"
        )

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 500
        body = json.loads(response["body"])
        assert "STS error" in body["error"]
        assert "ServiceUnavailable" in body["error"]


class TestConfigurationErrors:
    """Tests for configuration error scenarios."""

    def test_missing_role_arn(self, valid_event, lambda_context, monkeypatch):
        """Test error when MACOS_APP_ROLE_ARN environment variable is missing."""
        # Arrange - remove the environment variable
        monkeypatch.delenv("MACOS_APP_ROLE_ARN", raising=False)

        # Act
        response = handler.lambda_handler(valid_event, lambda_context)

        # Assert
        assert response["statusCode"] == 500
        body = json.loads(response["body"])
        assert "misconfiguration" in body["error"].lower()
        assert "MACOS_APP_ROLE_ARN" in body["error"]


class TestHelperFunctions:
    """Tests for helper functions."""

    def test_parse_body_with_string(self):
        """Test _parse_body with JSON string."""
        # Arrange
        event = {
            "body": json.dumps({"key": "value"})
        }

        # Act
        result = handler._parse_body(event)

        # Assert
        assert result == {"key": "value"}

    def test_parse_body_with_dict(self):
        """Test _parse_body with dict."""
        # Arrange
        event = {
            "body": {"key": "value"}
        }

        # Act
        result = handler._parse_body(event)

        # Assert
        assert result == {"key": "value"}

    def test_parse_body_invalid_json(self):
        """Test _parse_body with invalid JSON."""
        # Arrange
        event = {
            "body": "{invalid json}"
        }

        # Act & Assert
        with pytest.raises(ValueError) as exc_info:
            handler._parse_body(event)

        assert "Invalid JSON" in str(exc_info.value)

    def test_error_response_structure(self):
        """Test _error_response creates proper response structure."""
        # Act
        response = handler._error_response(400, "Test error message")

        # Assert
        assert response["statusCode"] == 400
        assert "headers" in response
        assert response["headers"]["Content-Type"] == "application/json"

        body = json.loads(response["body"])
        assert body["error"] == "Test error message"
