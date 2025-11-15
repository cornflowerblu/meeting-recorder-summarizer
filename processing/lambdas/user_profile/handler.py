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
from datetime import datetime

# AWS X-Ray SDK for distributed tracing
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

# Patch all AWS SDK calls (auto-traces DynamoDB)
patch_all()

# Initialize DynamoDB client
dynamodb = boto3.resource('dynamodb')
users_table_name = os.environ['USERS_TABLE_NAME']
users_table = dynamodb.Table(users_table_name)


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

    email = detail.get('email', '')
    display_name = detail.get('displayName')
    photo_url = detail.get('photoURL')
    provider = detail.get('provider')
    timestamp = detail.get('timestamp')

    # Add searchable X-Ray annotations for filtering traces
    xray_recorder.put_annotation('user_id', user_id)
    xray_recorder.put_annotation('event_source', 'EventBridge')

    # Validate timestamp
    if not timestamp:
        timestamp = datetime.utcnow().isoformat() + 'Z'
        print(f"WARNING: No timestamp in event, using current time: {timestamp}")

    try:
        # Check if user exists to preserve createdAt (DynamoDB call auto-traced by patch_all)
        with xray_recorder.capture('dynamodb_get_user'):
            response = users_table.get_item(Key={'userId': user_id})
            existing_user = response.get('Item')

        # Use existing createdAt if user exists, otherwise use current timestamp
        created_at = existing_user.get('createdAt') if existing_user else timestamp
        is_new_user = existing_user is None

        # Add annotation for whether this is a new user
        xray_recorder.put_annotation('action', 'created' if is_new_user else 'updated')

        # Build user item
        item = {
            'userId': user_id,
            'email': email,
            'lastLoginDate': timestamp,
            'createdAt': created_at
        }

        # Add optional fields if provided
        if display_name:
            item['displayName'] = display_name
        if photo_url:
            item['photoURL'] = photo_url
        if provider:
            item['provider'] = provider

        # Write to DynamoDB (auto-traced by patch_all)
        with xray_recorder.capture('dynamodb_put_user'):
            users_table.put_item(Item=item)

        # Add metadata (not searchable, but visible in trace details)
        xray_recorder.put_metadata('user_email', email)
        print(f"User profile {'created' if is_new_user else 'updated'}: {user_id} ({email})")

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
