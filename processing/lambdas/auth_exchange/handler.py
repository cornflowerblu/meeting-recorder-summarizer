"""
Firebase to AWS STS credentials exchange Lambda
MR-17 (T010)

Exchanges Firebase ID tokens for temporary AWS credentials using STS AssumeRoleWithWebIdentity.
Also emits user.signed_in events to EventBridge for downstream processing.
"""

import json
import os
import re
from datetime import datetime
from typing import Any, Dict, Optional

import boto3
from botocore.exceptions import ClientError

# AWS X-Ray SDK for distributed tracing
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls (boto3) - auto-traces STS, EventBridge, etc.
patch_all()

# Environment variables
MACOS_APP_ROLE_ARN = os.environ.get("MACOS_APP_ROLE_ARN")
SESSION_DURATION = int(os.environ.get("SESSION_DURATION", "3600"))  # 1 hour default
EVENT_BUS_NAME = os.environ.get("EVENT_BUS_NAME", "default")

# AWS clients
sts_client = boto3.client("sts")
eventbridge_client = boto3.client("events")


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Exchange Firebase ID token for temporary AWS credentials.

    Expected event body (JSON):
    {
        "id_token": "<firebase_id_token>",
        "session_name": "<firebase_user_id>",  # REQUIRED: Firebase user ID for IAM isolation
        "email": "<user@example.com>",         # OPTIONAL: For EventBridge events
        "display_name": "<John Doe>",          # OPTIONAL: For EventBridge events
        "photo_url": "<https://...>",          # OPTIONAL: For EventBridge events
        "provider": "<google.com>"             # OPTIONAL: For EventBridge events
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
            xray_recorder.put_annotation('auth_result', 'validation_error')
            xray_recorder.put_annotation('error_type', 'ValueError')
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

        # Call STS AssumeRoleWithWebIdentity with X-Ray tracing
        try:
            with xray_recorder.capture('sts_assume_role'):
                response = sts_client.assume_role_with_web_identity(
                    RoleArn=MACOS_APP_ROLE_ARN,
                    RoleSessionName=session_name,
                    WebIdentityToken=id_token,
                    DurationSeconds=SESSION_DURATION,
                )
        except ClientError as e:
            error_code = e.response["Error"]["Code"]
            error_message = e.response["Error"]["Message"]

            # Add X-Ray annotations for error tracking
            xray_recorder.put_annotation('auth_result', 'failure')
            xray_recorder.put_annotation('error_code', error_code)

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

        # Add searchable X-Ray annotations for filtering traces
        xray_recorder.put_annotation('user_id', session_name)
        xray_recorder.put_annotation('auth_result', 'success')

        # Add metadata (not searchable, but visible in trace details)
        if provider:
            xray_recorder.put_metadata('firebase_provider', provider)

        # Emit user.signed_in event to EventBridge (async, fire-and-forget)
        # Extract optional user profile fields
        user_email = body.get("email")
        display_name = body.get("display_name")
        photo_url = body.get("photo_url")
        provider = body.get("provider")

        try:
            with xray_recorder.capture('emit_user_signed_in_event'):
                _emit_user_signed_in_event(
                    user_id=session_name,
                    email=user_email,
                    display_name=display_name,
                    photo_url=photo_url,
                    provider=provider
                )
        except Exception as e:
            # Log error but don't fail the token exchange
            print(f"Failed to emit user.signed_in event: {str(e)}")

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


def _emit_user_signed_in_event(
    user_id: str,
    email: Optional[str] = None,
    display_name: Optional[str] = None,
    photo_url: Optional[str] = None,
    provider: Optional[str] = None
) -> None:
    """
    Emit user.signed_in event to EventBridge.

    This event triggers downstream processing like user profile creation,
    analytics, welcome emails, etc.

    Args:
        user_id: Firebase user ID
        email: User email address (optional)
        display_name: User display name (optional)
        photo_url: User photo URL (optional)
        provider: Authentication provider (optional)
    """
    # Build event detail with all available user data
    detail = {
        "userId": user_id,
        "timestamp": datetime.utcnow().isoformat() + "Z"
    }

    if email:
        detail["email"] = email
    if display_name:
        detail["displayName"] = display_name
    if photo_url:
        detail["photoURL"] = photo_url
    if provider:
        detail["provider"] = provider

    # Publish event to EventBridge
    eventbridge_client.put_events(
        Entries=[
            {
                "Source": "interview-companion.auth",
                "DetailType": "user.signed_in",
                "Detail": json.dumps(detail),
                "EventBusName": EVENT_BUS_NAME
            }
        ]
    )

    print(f"Emitted user.signed_in event for user: {user_id}")


def _error_response(status_code: int, message: str) -> Dict[str, Any]:
    """Create standardized error response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
