"""
Firebase to AWS STS credentials exchange Lambda
MR-17 (T010)

Exchanges Firebase ID tokens for temporary AWS credentials using STS AssumeRoleWithWebIdentity.
"""

import json
import os
import re
from typing import Any, Dict

import boto3
from botocore.exceptions import ClientError

# Environment variables
MACOS_APP_ROLE_ARN = os.environ.get("MACOS_APP_ROLE_ARN")
SESSION_DURATION = int(os.environ.get("SESSION_DURATION", "3600"))  # 1 hour default

# AWS clients
sts_client = boto3.client("sts")


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Exchange Firebase ID token for temporary AWS credentials.

    Expected event body (JSON):
    {
        "id_token": "<firebase_id_token>",
        "session_name": "<firebase_user_id>"  # REQUIRED: Firebase user ID for IAM isolation
    }

    Returns:
    {
        "statusCode": 200,
        "body": {
            "credentials": {
                "AccessKeyId": "...",
                "SecretAccessKey": "...",
                "SessionToken": "...",
                "Expiration": "2025-11-10T19:00:00Z"
            },
            "assumed_role_user": {
                "AssumedRoleId": "...",
                "Arn": "..."
            }
        }
    }
    """
    try:
        # Parse request body
        try:
            body = _parse_body(event)
        except ValueError as e:
            return _error_response(400, str(e))

        # Extract and validate Firebase ID token
        id_token = body.get("id_token")
        if not id_token:
            return _error_response(400, "Missing required field: id_token")

        if not isinstance(id_token, str):
            return _error_response(400, "Invalid id_token: must be a string")

        if len(id_token) > 4096:
            return _error_response(400, "Invalid id_token: token too large")

        if len(id_token) < 10:
            return _error_response(400, "Invalid id_token: token too short")

        # Extract and validate session name
        # Session name MUST be the Firebase user ID for IAM policy user isolation
        session_name = body.get("session_name")
        if not session_name:
            return _error_response(400, "Missing required field: session_name (Firebase user ID)")

        if not isinstance(session_name, str):
            return _error_response(400, "Invalid session_name: must be a string")

        # Sanitize session name: AWS allows alphanumeric, =,.@-_
        # Remove any other characters to prevent injection
        session_name = re.sub(r'[^a-zA-Z0-9=,.@_-]', '_', session_name[:64])

        # Validate environment configuration
        if not MACOS_APP_ROLE_ARN:
            return _error_response(500, "Server misconfiguration: MACOS_APP_ROLE_ARN not set")

        # Call STS AssumeRoleWithWebIdentity
        try:
            response = sts_client.assume_role_with_web_identity(
                RoleArn=MACOS_APP_ROLE_ARN,
                RoleSessionName=session_name,
                WebIdentityToken=id_token,
                DurationSeconds=SESSION_DURATION,
            )
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            error_message = e.response["Error"]["Message"]

            if error_code == "InvalidIdentityToken":
                return _error_response(401, "Invalid Firebase ID token")
            elif error_code == "ExpiredTokenException":
                return _error_response(401, "Firebase ID token has expired")
            elif error_code == "AccessDenied":
                return _error_response(403, "Access denied: Unable to assume role")
            else:
                return _error_response(500, f"STS error: {error_code} - {error_message}")

        # Extract credentials
        credentials = response["Credentials"]
        assumed_role_user = response["AssumedRoleUser"]

        # Return success response
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "credentials": {
                        "AccessKeyId": credentials["AccessKeyId"],
                        "SecretAccessKey": credentials["SecretAccessKey"],
                        "SessionToken": credentials["SessionToken"],
                        "Expiration": credentials["Expiration"].isoformat(),
                    },
                    "assumed_role_user": {
                        "AssumedRoleId": assumed_role_user["AssumedRoleId"],
                        "Arn": assumed_role_user["Arn"],
                    },
                }
            ),
        }

    except Exception as e:
        print(f"Unexpected error: {str(e)}")
        return _error_response(500, f"Internal server error: {str(e)}")


def _parse_body(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parse request body from event.

    Raises:
        ValueError: If body contains invalid JSON
    """
    body = event.get("body", "{}")

    # If body is a string, parse as JSON
    if isinstance(body, str):
        try:
            return json.loads(body)
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON in request body: {e}")

    # If body is already a dict, return as-is
    return body


def _error_response(status_code: int, message: str) -> Dict[str, Any]:
    """Create standardized error response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
