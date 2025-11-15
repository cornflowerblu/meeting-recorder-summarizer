"""
UserProfile Lambda Handler

Handles user.signed_in events from EventBridge and creates/updates user profiles
in the DynamoDB Users table.

Event Schema:
{
  "version": "0",
  "id": "uuid",
  "detail-type": "user.signed_in",
  "source": "interview-companion.auth",
  "time": "2025-11-14T20:00:00Z",
  "detail": {
    "userId": "firebase_uid_abc123",
    "email": "user@example.com",
    "displayName": "John Doe",
    "photoURL": "https://...",
    "provider": "google.com",
    "timestamp": "2025-11-14T20:00:00Z"
  }
}
"""

import boto3
import os
import json
from datetime import datetime, timezone

# AWS X-Ray SDK for distributed tracing
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls (auto-traces DynamoDB)
patch_all()

# Initialize DynamoDB client (lazy to support testing)
dynamodb = boto3.resource('dynamodb')
users_table = None


def _get_table():
    """Get users table, initializing if needed."""
    global users_table
    if users_table is None:
        users_table_name = os.environ['USERS_TABLE_NAME']
        users_table = dynamodb.Table(users_table_name)
    return users_table


def handler(event, context):
    """
    Handle user.signed_in events from EventBridge

    Creates or updates user profile in DynamoDB Users table.
    Preserves createdAt timestamp for existing users.

    Args:
        event: EventBridge event with user sign-in data
        context: Lambda context object

    Returns:
        dict: Response with statusCode and body
    """
    print(f"Received event: {json.dumps(event)}")

    # Extract user data from event detail
    detail = event.get('detail', {})

    user_id = detail.get('userId')
    if not user_id:
        print("ERROR: No userId in event detail")
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'userId is required'})
        }

    email = detail.get('email')
    display_name = detail.get('displayName')
    photo_url = detail.get('photoURL')
    provider = detail.get('provider')
    timestamp = detail.get('timestamp')

    # Validate timestamp
    if not timestamp:
        timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        print(f"WARNING: No timestamp in event, using current time: {timestamp}")

    try:
        # Get DynamoDB table
        table = _get_table()
        
        # Check if user exists to preserve createdAt (DynamoDB call auto-traced by patch_all)
        response = table.get_item(Key={'userId': user_id})
        existing_user = response.get('Item')

        # Use existing createdAt if user exists, otherwise use current timestamp
        created_at = existing_user.get('createdAt') if existing_user else timestamp
        is_new_user = existing_user is None

        # Build user item with required fields
        item = {
            'userId': user_id,
            'lastLoginDate': timestamp,
            'createdAt': created_at
        }

        # Add optional fields only if they are non-empty strings
        if email and isinstance(email, str) and email.strip():
            item['email'] = email.strip()
        if display_name and isinstance(display_name, str) and display_name.strip():
            item['displayName'] = display_name.strip()
        if photo_url and isinstance(photo_url, str) and photo_url.strip():
            item['photoURL'] = photo_url.strip()
        if provider and isinstance(provider, str) and provider.strip():
            item['provider'] = provider.strip()

        # Write to DynamoDB (auto-traced by patch_all)
        table.put_item(Item=item)

        action = 'created' if is_new_user else 'updated'
        email_display = item.get('email', 'no-email')
        print(f"User profile {action}: {user_id} ({email_display})")

        return {
            'statusCode': 200,
            'body': json.dumps({
                'userId': user_id,
                'email': email,
                'action': 'created' if is_new_user else 'updated',
                'timestamp': timestamp
            })
        }

    except Exception as e:
        print(f"ERROR updating user profile: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }
