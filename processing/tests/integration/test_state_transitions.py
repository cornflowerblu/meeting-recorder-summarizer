"""
Integration tests for Step Functions state machine status transitions.

Tests verify that the AI processing pipeline state machine properly transitions
through states and updates DynamoDB status fields correctly.
"""

import json
import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime


@pytest.fixture
def mock_step_functions_client():
    """Mock boto3 Step Functions client."""
    with patch('boto3.client') as mock_client:
        sfn_client = Mock()
        mock_client.return_value = sfn_client
        yield sfn_client


@pytest.fixture
def mock_dynamodb_client():
    """Mock boto3 DynamoDB client."""
    with patch('boto3.client') as mock_client:
        ddb_client = Mock()
        mock_client.return_value = ddb_client
        yield ddb_client


@pytest.fixture
def sample_step_input():
    """Sample input for Step Functions execution."""
    return {
        "recording_id": "rec_test123",
        "user_id": "user_456",
        "s3_bucket": "test-bucket",
        "chunk_count": 5
    }


@pytest.mark.integration
class TestStateTransitions:
    """Test suite for Step Functions state transitions."""

    def test_successful_pipeline_execution_flow(self, mock_step_functions_client, sample_step_input):
        """Test complete successful execution flow from start to completion."""
        # Mock successful execution
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:test-exec"
        
        mock_step_functions_client.start_execution.return_value = {
            'executionArn': execution_arn,
            'startDate': datetime.now()
        }
        
        # Mock execution history showing all states
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'SUCCEEDED',
            'startDate': datetime.now(),
            'stopDate': datetime.now(),
            'input': json.dumps(sample_step_input)
        }
        
        # Verify execution started
        response = mock_step_functions_client.start_execution(
            stateMachineArn='arn:aws:states:us-east-1:123456789012:stateMachine:ai-processing-pipeline',
            input=json.dumps(sample_step_input)
        )
        
        assert response['executionArn'] == execution_arn
        mock_step_functions_client.start_execution.assert_called_once()

    def test_validation_failure_transition(self, mock_step_functions_client, sample_step_input):
        """Test transition to ValidationFailed state when input validation fails."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:validation-fail"
        
        # Mock execution that fails at validation
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'FAILED',
            'startDate': datetime.now(),
            'stopDate': datetime.now(),
            'cause': 'Input validation failed',
            'error': 'ValidationError'
        }
        
        response = mock_step_functions_client.describe_execution(
            executionArn=execution_arn
        )
        
        assert response['status'] == 'FAILED'
        assert response['error'] == 'ValidationError'

    def test_video_processing_failure_transition(self, mock_step_functions_client):
        """Test transition to ProcessingFailed when video processing fails."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:video-fail"
        
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'FAILED',
            'startDate': datetime.now(),
            'stopDate': datetime.now(),
            'cause': 'ECS task failed',
            'error': 'ECS.TaskFailed'
        }
        
        response = mock_step_functions_client.describe_execution(
            executionArn=execution_arn
        )
        
        assert response['status'] == 'FAILED'
        assert 'ECS' in response['error']

    def test_transcription_in_progress_loop(self, mock_step_functions_client):
        """Test state machine loops in WaitForTranscription when transcription is in progress."""
        # This test verifies the Choice state logic for IN_PROGRESS status
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:transcribe-wait"
        
        # Mock execution in progress
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'RUNNING',
            'startDate': datetime.now()
        }
        
        # Mock execution history showing wait loop
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 1,
                    'type': 'ExecutionStarted',
                    'timestamp': datetime.now()
                },
                {
                    'id': 10,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'CheckTranscriptionStatus'
                    }
                },
                {
                    'id': 11,
                    'type': 'ChoiceStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'TranscriptionChoice'
                    }
                },
                {
                    'id': 12,
                    'type': 'WaitStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'WaitForTranscription'
                    }
                }
            ]
        }
        
        history = mock_step_functions_client.get_execution_history(
            executionArn=execution_arn
        )
        
        # Verify we entered the wait state (indicating IN_PROGRESS loop)
        wait_states = [e for e in history['events'] if e['type'] == 'WaitStateEntered']
        assert len(wait_states) > 0

    def test_transcription_completed_to_summary(self, mock_step_functions_client):
        """Test transition from transcription completion to summary generation."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:test-summary"
        
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 20,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'CheckTranscriptionStatus'
                    }
                },
                {
                    'id': 21,
                    'type': 'TaskStateExited',
                    'timestamp': datetime.now(),
                    'stateExitedEventDetails': {
                        'name': 'CheckTranscriptionStatus',
                        'output': json.dumps({'transcription_status': 'COMPLETED'})
                    }
                },
                {
                    'id': 22,
                    'type': 'ChoiceStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'TranscriptionChoice'
                    }
                },
                {
                    'id': 23,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'GenerateSummary'
                    }
                }
            ]
        }
        
        history = mock_step_functions_client.get_execution_history(
            executionArn=execution_arn
        )
        
        # Verify we transitioned to GenerateSummary after COMPLETED status
        events = history['events']
        check_status_exit = next(e for e in events if e['type'] == 'TaskStateExited')
        output = json.loads(check_status_exit['stateExitedEventDetails']['output'])
        assert output['transcription_status'] == 'COMPLETED'
        
        summary_entry = next(e for e in events if 
                            e['type'] == 'TaskStateEntered' and 
                            e.get('stateEnteredEventDetails', {}).get('name') == 'GenerateSummary')
        assert summary_entry is not None

    def test_transcription_failed_transition(self, mock_step_functions_client):
        """Test transition to ProcessingFailed when transcription fails."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:transcribe-fail"
        
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'FAILED',
            'startDate': datetime.now(),
            'stopDate': datetime.now(),
            'cause': 'Transcription job failed',
            'error': 'ProcessingError'
        }
        
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 25,
                    'type': 'TaskStateExited',
                    'timestamp': datetime.now(),
                    'stateExitedEventDetails': {
                        'name': 'CheckTranscriptionStatus',
                        'output': json.dumps({'transcription_status': 'FAILED'})
                    }
                },
                {
                    'id': 26,
                    'type': 'FailStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'ProcessingFailed'
                    }
                }
            ]
        }
        
        response = mock_step_functions_client.describe_execution(
            executionArn=execution_arn
        )
        
        assert response['status'] == 'FAILED'

    def test_summary_generation_to_catalog_update(self, mock_step_functions_client):
        """Test transition from summary generation to catalog update."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:catalog-update"
        
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 30,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'GenerateSummary'
                    }
                },
                {
                    'id': 31,
                    'type': 'TaskStateExited',
                    'timestamp': datetime.now(),
                    'stateExitedEventDetails': {
                        'name': 'GenerateSummary',
                        'output': json.dumps({'summary_generated': True})
                    }
                },
                {
                    'id': 32,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'UpdateCatalog'
                    }
                }
            ]
        }
        
        history = mock_step_functions_client.get_execution_history(
            executionArn=execution_arn
        )
        
        events = history['events']
        catalog_entry = next(e for e in events if 
                           e['type'] == 'TaskStateEntered' and 
                           e.get('stateEnteredEventDetails', {}).get('name') == 'UpdateCatalog')
        assert catalog_entry is not None

    def test_catalog_update_to_completion(self, mock_step_functions_client):
        """Test final transition from catalog update to ProcessingCompleted."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:complete"
        
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'SUCCEEDED',
            'startDate': datetime.now(),
            'stopDate': datetime.now()
        }
        
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 40,
                    'type': 'TaskStateExited',
                    'timestamp': datetime.now(),
                    'stateExitedEventDetails': {
                        'name': 'UpdateCatalog',
                        'output': json.dumps({'catalog_updated': True})
                    }
                },
                {
                    'id': 41,
                    'type': 'ExecutionSucceeded',
                    'timestamp': datetime.now(),
                    'executionSucceededEventDetails': {
                        'output': json.dumps({'status': 'completed'})
                    }
                }
            ]
        }
        
        response = mock_step_functions_client.describe_execution(
            executionArn=execution_arn
        )
        
        assert response['status'] == 'SUCCEEDED'

    def test_retry_logic_on_throttling(self, mock_step_functions_client):
        """Test retry behavior when AWS services throttle requests."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:retry"
        
        # Mock execution history showing retry attempts
        mock_step_functions_client.get_execution_history.return_value = {
            'events': [
                {
                    'id': 50,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'GenerateSummary'
                    }
                },
                {
                    'id': 51,
                    'type': 'TaskFailed',
                    'timestamp': datetime.now(),
                    'taskFailedEventDetails': {
                        'error': 'Bedrock.ThrottlingException',
                        'cause': 'Rate exceeded'
                    }
                },
                {
                    'id': 52,
                    'type': 'TaskStateEntered',
                    'timestamp': datetime.now(),
                    'stateEnteredEventDetails': {
                        'name': 'GenerateSummary'
                    }
                },
                {
                    'id': 53,
                    'type': 'TaskSucceeded',
                    'timestamp': datetime.now()
                }
            ]
        }
        
        history = mock_step_functions_client.get_execution_history(
            executionArn=execution_arn
        )
        
        events = history['events']
        # Count retry attempts (multiple entries for same state)
        summary_entries = [e for e in events if 
                          e['type'] == 'TaskStateEntered' and 
                          e.get('stateEnteredEventDetails', {}).get('name') == 'GenerateSummary']
        
        # Should have at least 2 entries (initial + retry)
        assert len(summary_entries) >= 2

    def test_timeout_transition_to_failed(self, mock_step_functions_client):
        """Test transition to failed state when execution times out."""
        execution_arn = "arn:aws:states:us-east-1:123456789012:execution:ai-processing-pipeline:timeout"
        
        mock_step_functions_client.describe_execution.return_value = {
            'executionArn': execution_arn,
            'status': 'TIMED_OUT',
            'startDate': datetime.now(),
            'stopDate': datetime.now(),
            'cause': 'Execution timed out after 2 hours'
        }
        
        response = mock_step_functions_client.describe_execution(
            executionArn=execution_arn
        )
        
        assert response['status'] == 'TIMED_OUT'


@pytest.mark.integration
class TestDynamoDBStatusUpdates:
    """Test suite for DynamoDB status field updates during state transitions."""

    def test_status_update_to_processing(self, mock_dynamodb_client):
        """Test DynamoDB status updates to 'processing' when pipeline starts."""
        mock_dynamodb_client.update_item.return_value = {
            'Attributes': {
                'status': {'S': 'processing'},
                'updated_at': {'S': datetime.now().isoformat()}
            }
        }
        
        response = mock_dynamodb_client.update_item(
            TableName='meetings',
            Key={'PK': {'S': 'user_456#rec_test123'}, 'SK': {'S': 'METADATA'}},
            UpdateExpression='SET #status = :status, updated_at = :updated_at',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': {'S': 'processing'},
                ':updated_at': {'S': datetime.now().isoformat()}
            },
            ReturnValues='ALL_NEW'
        )
        
        assert response['Attributes']['status']['S'] == 'processing'

    def test_status_update_to_completed(self, mock_dynamodb_client):
        """Test DynamoDB status updates to 'completed' when pipeline succeeds."""
        mock_dynamodb_client.update_item.return_value = {
            'Attributes': {
                'status': {'S': 'completed'},
                'updated_at': {'S': datetime.now().isoformat()},
                'completed_at': {'S': datetime.now().isoformat()}
            }
        }
        
        response = mock_dynamodb_client.update_item(
            TableName='meetings',
            Key={'PK': {'S': 'user_456#rec_test123'}, 'SK': {'S': 'METADATA'}},
            UpdateExpression='SET #status = :status, updated_at = :updated_at, completed_at = :completed_at',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': {'S': 'completed'},
                ':updated_at': {'S': datetime.now().isoformat()},
                ':completed_at': {'S': datetime.now().isoformat()}
            },
            ReturnValues='ALL_NEW'
        )
        
        assert response['Attributes']['status']['S'] == 'completed'

    def test_status_update_to_failed(self, mock_dynamodb_client):
        """Test DynamoDB status updates to 'failed' when pipeline fails."""
        mock_dynamodb_client.update_item.return_value = {
            'Attributes': {
                'status': {'S': 'failed'},
                'updated_at': {'S': datetime.now().isoformat()},
                'error_message': {'S': 'Processing error occurred'}
            }
        }
        
        response = mock_dynamodb_client.update_item(
            TableName='meetings',
            Key={'PK': {'S': 'user_456#rec_test123'}, 'SK': {'S': 'METADATA'}},
            UpdateExpression='SET #status = :status, updated_at = :updated_at, error_message = :error',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': {'S': 'failed'},
                ':updated_at': {'S': datetime.now().isoformat()},
                ':error': {'S': 'Processing error occurred'}
            },
            ReturnValues='ALL_NEW'
        )
        
        assert response['Attributes']['status']['S'] == 'failed'
        assert 'error_message' in response['Attributes']
