"""
Multi-Tenant Isolation Security Tests

Tests that validate Firebase UID-based multi-tenancy enforced through IAM policies.
These tests verify that User A cannot access User B's data in S3 or DynamoDB.

IMPORTANT: These tests require actual AWS credentials with IAM conditions applied.
Run against a dedicated test environment, NOT production.

Reference: security-analysis-token-swap.md (PR #30)
"""

import pytest
import boto3
from botocore.exceptions import ClientError
import os
import time


# Test configuration
TEST_BUCKET = os.getenv('TEST_S3_BUCKET', 'meeting-recorder-test-recordings')
TEST_TABLE = os.getenv('TEST_DYNAMODB_TABLE', 'meeting-recorder-test-meetings')

# Test user credentials (obtained from auth_exchange Lambda with different Firebase UIDs)
# These should be temporary STS credentials scoped to each user
USER_A_CREDENTIALS = {
    'aws_access_key_id': os.getenv('USER_A_ACCESS_KEY'),
    'aws_secret_access_key': os.getenv('USER_A_SECRET_KEY'),
    'aws_session_token': os.getenv('USER_A_SESSION_TOKEN'),
    'firebase_uid': os.getenv('USER_A_UID', 'test-user-a-123')
}

USER_B_CREDENTIALS = {
    'aws_access_key_id': os.getenv('USER_B_ACCESS_KEY'),
    'aws_secret_access_key': os.getenv('USER_B_SECRET_KEY'),
    'aws_session_token': os.getenv('USER_B_SESSION_TOKEN'),
    'firebase_uid': os.getenv('USER_B_UID', 'test-user-b-456')
}


@pytest.fixture
def user_a_s3_client():
    """S3 client authenticated as User A"""
    return boto3.client(
        's3',
        aws_access_key_id=USER_A_CREDENTIALS['aws_access_key_id'],
        aws_secret_access_key=USER_A_CREDENTIALS['aws_secret_access_key'],
        aws_session_token=USER_A_CREDENTIALS['aws_session_token'],
        region_name='us-east-1'
    )


@pytest.fixture
def user_b_s3_client():
    """S3 client authenticated as User B"""
    return boto3.client(
        's3',
        aws_access_key_id=USER_B_CREDENTIALS['aws_access_key_id'],
        aws_secret_access_key=USER_B_CREDENTIALS['aws_secret_access_key'],
        aws_session_token=USER_B_CREDENTIALS['aws_session_token'],
        region_name='us-east-1'
    )


@pytest.fixture
def user_a_dynamodb_client():
    """DynamoDB client authenticated as User A"""
    return boto3.client(
        'dynamodb',
        aws_access_key_id=USER_A_CREDENTIALS['aws_access_key_id'],
        aws_secret_access_key=USER_A_CREDENTIALS['aws_secret_access_key'],
        aws_session_token=USER_A_CREDENTIALS['aws_session_token'],
        region_name='us-east-1'
    )


@pytest.fixture
def user_b_dynamodb_client():
    """DynamoDB client authenticated as User B"""
    return boto3.client(
        'dynamodb',
        aws_access_key_id=USER_B_CREDENTIALS['aws_access_key_id'],
        aws_secret_access_key=USER_B_CREDENTIALS['aws_secret_access_key'],
        aws_session_token=USER_B_CREDENTIALS['aws_session_token'],
        region_name='us-east-1'
    )


@pytest.fixture
def admin_s3_client():
    """Admin S3 client for test setup/teardown"""
    return boto3.client('s3', region_name='us-east-1')


@pytest.fixture
def admin_dynamodb_client():
    """Admin DynamoDB client for test setup/teardown"""
    return boto3.client('dynamodb', region_name='us-east-1')


# ==============================================================================
# Test 1: S3 Cross-User Access Blocked
# ==============================================================================

@pytest.mark.security
@pytest.mark.integration
def test_s3_cross_user_access_blocked(user_a_s3_client, user_b_s3_client, admin_s3_client):
    """
    SECURITY TEST: User A cannot read User B's S3 objects

    IAM Policy Enforcement:
    - S3 PutObject restricted to: s3:prefix = "users/${aws:userid}/*"
    - S3 GetObject restricted to: s3:prefix = "users/${aws:userid}/*"

    Expected: AccessDenied when User A tries to read User B's object
    """
    user_b_uid = USER_B_CREDENTIALS['firebase_uid']
    user_b_key = f"users/{user_b_uid}/chunks/test-recording-123/chunk_000.mp4"

    # Setup: Admin creates object for User B
    admin_s3_client.put_object(
        Bucket=TEST_BUCKET,
        Key=user_b_key,
        Body=b'test video data for user B'
    )

    try:
        # User B should be able to read their own object
        response = user_b_s3_client.get_object(
            Bucket=TEST_BUCKET,
            Key=user_b_key
        )
        assert response['ResponseMetadata']['HTTPStatusCode'] == 200
        print(f"✓ User B can read their own object: {user_b_key}")

        # User A should NOT be able to read User B's object
        with pytest.raises(ClientError) as exc_info:
            user_a_s3_client.get_object(
                Bucket=TEST_BUCKET,
                Key=user_b_key
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDenied'
        print(f"✓ User A correctly blocked from reading User B's object")
        print(f"  Error message: {error.response['Error']['Message']}")

    finally:
        # Cleanup
        admin_s3_client.delete_object(Bucket=TEST_BUCKET, Key=user_b_key)


# ==============================================================================
# Test 2: DynamoDB Cross-User Query Blocked (LeadingKeys)
# ==============================================================================

@pytest.mark.security
@pytest.mark.integration
def test_dynamodb_cross_user_query_blocked(user_a_dynamodb_client, user_b_dynamodb_client, admin_dynamodb_client):
    """
    SECURITY TEST: User A cannot query User B's DynamoDB records

    IAM Policy Enforcement:
    - DynamoDB LeadingKeys condition: dynamodb:LeadingKeys = "${aws:userid}#*"
    - This restricts partition key to start with user's Firebase UID

    Expected: AccessDeniedException when User A tries to query User B's partition
    """
    user_a_uid = USER_A_CREDENTIALS['firebase_uid']
    user_b_uid = USER_B_CREDENTIALS['firebase_uid']

    user_a_pk = f"{user_a_uid}#recording-abc"
    user_b_pk = f"{user_b_uid}#recording-xyz"

    # Setup: Admin creates items for both users
    admin_dynamodb_client.put_item(
        TableName=TEST_TABLE,
        Item={
            'pk': {'S': user_a_pk},
            'sk': {'S': 'METADATA'},
            'title': {'S': 'User A recording'}
        }
    )

    admin_dynamodb_client.put_item(
        TableName=TEST_TABLE,
        Item={
            'pk': {'S': user_b_pk},
            'sk': {'S': 'METADATA'},
            'title': {'S': 'User B recording (secret)'}
        }
    )

    try:
        # User A should be able to read their own item
        response = user_a_dynamodb_client.get_item(
            TableName=TEST_TABLE,
            Key={
                'pk': {'S': user_a_pk},
                'sk': {'S': 'METADATA'}
            }
        )
        assert 'Item' in response
        assert response['Item']['title']['S'] == 'User A recording'
        print(f"✓ User A can read their own item: {user_a_pk}")

        # User A should NOT be able to read User B's item
        with pytest.raises(ClientError) as exc_info:
            user_a_dynamodb_client.get_item(
                TableName=TEST_TABLE,
                Key={
                    'pk': {'S': user_b_pk},
                    'sk': {'S': 'METADATA'}
                }
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDeniedException'
        print(f"✓ User A correctly blocked from reading User B's item")
        print(f"  Error message: {error.response['Error']['Message']}")

        # User A should NOT be able to query User B's partition
        with pytest.raises(ClientError) as exc_info:
            user_a_dynamodb_client.query(
                TableName=TEST_TABLE,
                KeyConditionExpression='pk = :pk',
                ExpressionAttributeValues={
                    ':pk': {'S': user_b_pk}
                }
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDeniedException'
        print(f"✓ User A correctly blocked from querying User B's partition")

    finally:
        # Cleanup
        admin_dynamodb_client.delete_item(
            TableName=TEST_TABLE,
            Key={'pk': {'S': user_a_pk}, 'sk': {'S': 'METADATA'}}
        )
        admin_dynamodb_client.delete_item(
            TableName=TEST_TABLE,
            Key={'pk': {'S': user_b_pk}, 'sk': {'S': 'METADATA'}}
        )


# ==============================================================================
# Test 3: S3 Path Traversal Blocked
# ==============================================================================

@pytest.mark.security
@pytest.mark.integration
def test_s3_path_traversal_blocked(user_a_s3_client, admin_s3_client):
    """
    SECURITY TEST: Path traversal attacks (../../) are prevented

    Attack Scenarios:
    1. User A tries to write to "../user-b/chunks/..." to escape their directory
    2. User A tries to read using path traversal to access User B's data

    IAM Policy Enforcement:
    - S3 prefix condition prevents writes/reads outside "users/${aws:userid}/*"

    Expected: AccessDenied for all path traversal attempts
    """
    user_a_uid = USER_A_CREDENTIALS['firebase_uid']
    user_b_uid = USER_B_CREDENTIALS['firebase_uid']

    # Setup: Admin creates a file in User B's directory
    user_b_key = f"users/{user_b_uid}/secret.txt"
    admin_s3_client.put_object(
        Bucket=TEST_BUCKET,
        Key=user_b_key,
        Body=b'secret data'
    )

    try:
        # Attack 1: Try to write outside allowed directory using ..
        malicious_write_key = f"users/{user_a_uid}/../{user_b_uid}/malicious.txt"

        with pytest.raises(ClientError) as exc_info:
            user_a_s3_client.put_object(
                Bucket=TEST_BUCKET,
                Key=malicious_write_key,
                Body=b'malicious data'
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDenied'
        print(f"✓ Path traversal write blocked: {malicious_write_key}")

        # Attack 2: Try to read User B's file using absolute path
        with pytest.raises(ClientError) as exc_info:
            user_a_s3_client.get_object(
                Bucket=TEST_BUCKET,
                Key=user_b_key
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDenied'
        print(f"✓ Direct access to User B's file blocked: {user_b_key}")

        # Attack 3: Try to read using traversal from User A's allowed path
        malicious_read_key = f"users/{user_a_uid}/../../{user_b_uid}/secret.txt"

        with pytest.raises(ClientError) as exc_info:
            user_a_s3_client.get_object(
                Bucket=TEST_BUCKET,
                Key=malicious_read_key
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDenied'
        print(f"✓ Path traversal read blocked: {malicious_read_key}")

        # Verify User A CAN still access their own directory
        user_a_valid_key = f"users/{user_a_uid}/chunks/test.mp4"
        user_a_s3_client.put_object(
            Bucket=TEST_BUCKET,
            Key=user_a_valid_key,
            Body=b'valid user A data'
        )

        response = user_a_s3_client.get_object(
            Bucket=TEST_BUCKET,
            Key=user_a_valid_key
        )
        assert response['ResponseMetadata']['HTTPStatusCode'] == 200
        print(f"✓ User A can still access their own directory normally")

        # Cleanup
        admin_s3_client.delete_object(Bucket=TEST_BUCKET, Key=user_a_valid_key)

    finally:
        # Cleanup
        admin_s3_client.delete_object(Bucket=TEST_BUCKET, Key=user_b_key)


# ==============================================================================
# Test 4: S3 ListObjects Scoped to User Directory
# ==============================================================================

@pytest.mark.security
@pytest.mark.integration
def test_s3_list_objects_scoped_to_user(user_a_s3_client, admin_s3_client):
    """
    SECURITY TEST: ListObjects only returns user's own objects

    IAM Policy Enforcement:
    - s3:ListBucket with condition: s3:prefix = "users/${aws:userid}/*"

    Expected: User A can only list objects in their own directory
    """
    user_a_uid = USER_A_CREDENTIALS['firebase_uid']
    user_b_uid = USER_B_CREDENTIALS['firebase_uid']

    # Setup: Create objects for both users
    user_a_key = f"users/{user_a_uid}/test-a.mp4"
    user_b_key = f"users/{user_b_uid}/test-b.mp4"

    admin_s3_client.put_object(Bucket=TEST_BUCKET, Key=user_a_key, Body=b'a')
    admin_s3_client.put_object(Bucket=TEST_BUCKET, Key=user_b_key, Body=b'b')

    try:
        # User A lists objects with their prefix - should succeed
        response = user_a_s3_client.list_objects_v2(
            Bucket=TEST_BUCKET,
            Prefix=f"users/{user_a_uid}/"
        )

        assert 'Contents' in response
        assert len(response['Contents']) == 1
        assert response['Contents'][0]['Key'] == user_a_key
        print(f"✓ User A can list their own objects")

        # User A tries to list ALL objects - should be denied or filtered
        # Depending on IAM policy, this might:
        # 1. Return AccessDenied
        # 2. Return empty list (if policy denies ListBucket without prefix)
        try:
            response = user_a_s3_client.list_objects_v2(Bucket=TEST_BUCKET)
            # If it succeeds, verify User B's objects are NOT included
            if 'Contents' in response:
                keys = [obj['Key'] for obj in response['Contents']]
                assert user_b_key not in keys
                print(f"✓ User B's objects not visible in unrestricted list")
        except ClientError as e:
            assert e.response['Error']['Code'] == 'AccessDenied'
            print(f"✓ Unrestricted ListObjects correctly denied")

        # User A tries to list User B's prefix - should be denied
        with pytest.raises(ClientError) as exc_info:
            user_a_s3_client.list_objects_v2(
                Bucket=TEST_BUCKET,
                Prefix=f"users/{user_b_uid}/"
            )

        error = exc_info.value
        assert error.response['Error']['Code'] == 'AccessDenied'
        print(f"✓ User A blocked from listing User B's prefix")

    finally:
        # Cleanup
        admin_s3_client.delete_object(Bucket=TEST_BUCKET, Key=user_a_key)
        admin_s3_client.delete_object(Bucket=TEST_BUCKET, Key=user_b_key)


# ==============================================================================
# Test Setup Instructions
# ==============================================================================

"""
HOW TO RUN THESE TESTS:

1. Set up two test users in Firebase
2. Get temporary STS credentials for each user via auth_exchange Lambda:

   curl -X POST https://API_GATEWAY_URL/auth/exchange \
     -H "Content-Type: application/json" \
     -d '{"idToken": "FIREBASE_ID_TOKEN_USER_A"}'

3. Set environment variables:

   export USER_A_ACCESS_KEY="ASIA..."
   export USER_A_SECRET_KEY="..."
   export USER_A_SESSION_TOKEN="..."
   export USER_A_UID="firebase-uid-a"

   export USER_B_ACCESS_KEY="ASIA..."
   export USER_B_SECRET_KEY="..."
   export USER_B_SESSION_TOKEN="..."
   export USER_B_UID="firebase-uid-b"

   export TEST_S3_BUCKET="meeting-recorder-dev-recordings"
   export TEST_DYNAMODB_TABLE="meeting-recorder-dev-meetings"

4. Run tests:

   pytest tests/security/test_multi_tenant_isolation.py -v -m security

Expected Results:
- ALL tests should PASS
- Each test should show AccessDenied errors (which is CORRECT behavior)
- No test user should be able to access another user's data

If any test FAILS (i.e., access is NOT denied), there is a CRITICAL security issue.
"""
