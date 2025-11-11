"""
Firebase to AWS STS credentials exchange Lambda
MR-17 (T010)

Exchanges Firebase ID tokens for temporary AWS credentials using STS AssumeRoleWithWebIdentity.
"""

import json
import os
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
        "session_name": "user_email_or_id"  # Optional, defaults to context.request_id
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
        body = _parse_body(event)

        # Extract Firebase ID token
        id_token = body.get("id_token")
        if not id_token:
            return _error_response(400, "Missing required field: id_token")

        # Session name (used for CloudTrail auditing)
        session_name = body.get("session_name", context.request_id)

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
    """Parse request body from event."""
    body = event.get("body", "{}")

    # If body is a string, parse as JSON
    if isinstance(body, str):
        return json.loads(body)

    # If body is already a dict, return as-is
    return body


def _error_response(status_code: int, message: str) -> Dict[str, Any]:
    """Create standardized error response."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
