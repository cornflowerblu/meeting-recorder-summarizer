"""
Contract tests for summary JSON schema validation.

Tests verify that summary artifacts conform to the schema defined in
specs/001-meeting-recorder-ai/contracts/schemas/summary.schema.json
"""

import json
import pytest
from pathlib import Path
from jsonschema import validate, ValidationError, Draft7Validator, FormatChecker


@pytest.fixture
def summary_schema():
    """Load summary JSON schema."""
    # Navigate from processing/tests/contracts to repo root
    schema_path = Path(__file__).parents[3] / "specs" / "001-meeting-recorder-ai" / "contracts" / "schemas" / "summary.schema.json"
    with open(schema_path) as f:
        return json.load(f)


@pytest.fixture
def sample_summary():
    """Load sample summary fixture."""
    fixture_path = Path(__file__).parent.parent / "fixtures" / "sample_summary.json"
    with open(fixture_path) as f:
        return json.load(f)


@pytest.mark.contract
class TestSummarySchemaValidation:
    """Test suite for summary schema validation."""

    def test_schema_is_valid(self, summary_schema):
        """Verify the schema itself is valid Draft 7 JSON Schema."""
        Draft7Validator.check_schema(summary_schema)

    def test_minimal_valid_summary(self, summary_schema):
        """Test that a minimal valid summary passes validation."""
        minimal_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "This is a test summary.",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=minimal_summary, schema=summary_schema)

    def test_complete_valid_summary(self, summary_schema):
        """Test that a complete summary with all fields passes validation."""
        complete_summary = {
            "recording_id": "rec_test456",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Comprehensive meeting summary covering project status and next steps.",
            "key_topics": [
                "Project timeline",
                "Budget allocation",
                "Resource planning"
            ],
            "highlights": [
                {
                    "text": "Reached agreement on Q4 milestones",
                    "timestamp_ms": 12000,
                    "speaker_name": "Alice"
                },
                {
                    "text": "Budget approved by stakeholders",
                    "timestamp_ms": 45000
                }
            ],
            "actions": [
                {
                    "id": "act_001",
                    "description": "Update project roadmap",
                    "owner": "Alice",
                    "due_date": "2025-11-20",
                    "status": "pending",
                    "source_timestamp_ms": 12000,
                    "confidence": 0.92
                },
                {
                    "id": "act_002",
                    "description": "Schedule team meeting",
                    "owner": "Bob",
                    "status": "completed",
                    "source_timestamp_ms": 25000,
                    "confidence": 0.88
                }
            ],
            "decisions": [
                {
                    "id": "dec_001",
                    "decision": "Move forward with cloud migration",
                    "rationale": "Cost savings and improved scalability",
                    "impact": "Will require 3 months of engineering time",
                    "source_timestamp_ms": 35000,
                    "confidence": 0.95
                },
                {
                    "id": "dec_002",
                    "decision": "Hire additional backend engineer",
                    "source_timestamp_ms": 50000,
                    "confidence": 0.85
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=complete_summary, schema=summary_schema)

    def test_missing_required_field_recording_id(self, summary_schema):
        """Test that missing recording_id fails validation."""
        invalid_summary = {
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'recording_id' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_generated_at(self, summary_schema):
        """Test that missing generated_at fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'generated_at' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_summary_text(self, summary_schema):
        """Test that missing summary_text fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'summary_text' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_actions(self, summary_schema):
        """Test that missing actions fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'actions' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_decisions(self, summary_schema):
        """Test that missing decisions fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'decisions' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_pipeline_version(self, summary_schema):
        """Test that missing pipeline_version fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [],
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError, match="'pipeline_version' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_missing_required_field_model_version(self, summary_schema):
        """Test that missing model_version fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0"
        }
        with pytest.raises(ValidationError, match="'model_version' is a required property"):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_action_item_missing_required_fields(self, summary_schema):
        """Test that action item missing required fields fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001"
                    # Missing description
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_decision_item_missing_required_fields(self, summary_schema):
        """Test that decision item missing required fields fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [
                {
                    "id": "dec_001"
                    # Missing decision
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_highlight_item_missing_required_fields(self, summary_schema):
        """Test that highlight item missing required fields fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "highlights": [
                {
                    "text": "Important moment"
                    # Missing timestamp_ms
                }
            ],
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_action_item_invalid_status_enum(self, summary_schema):
        """Test that action item with invalid status fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001",
                    "description": "Do something",
                    "status": "invalid_status"  # Must be pending/completed/cancelled
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_negative_timestamp_ms_fails(self, summary_schema):
        """Test that negative timestamp_ms fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001",
                    "description": "Do something",
                    "source_timestamp_ms": -100  # Must be >= 0
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_confidence_out_of_range_fails(self, summary_schema):
        """Test that confidence value outside [0,1] range fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001",
                    "description": "Do something",
                    "confidence": 1.5  # Must be <= 1.0
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema)

    def test_action_item_with_optional_fields(self, summary_schema):
        """Test action item validation with only required fields."""
        summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001",
                    "description": "Do something"
                    # owner, due_date, status, source_timestamp_ms, confidence are optional
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=summary, schema=summary_schema)

    def test_decision_item_with_optional_fields(self, summary_schema):
        """Test decision item validation with only required fields."""
        summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [
                {
                    "id": "dec_001",
                    "decision": "Make a choice"
                    # rationale, impact, source_timestamp_ms, confidence are optional
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=summary, schema=summary_schema)

    def test_highlight_item_with_optional_speaker(self, summary_schema):
        """Test highlight item validation without optional speaker_name."""
        summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "highlights": [
                {
                    "text": "Important point",
                    "timestamp_ms": 12000
                    # speaker_name is optional
                }
            ],
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=summary, schema=summary_schema)

    def test_key_topics_array(self, summary_schema):
        """Test key_topics array validation."""
        summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "key_topics": ["Topic 1", "Topic 2", "Topic 3"],
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        validate(instance=summary, schema=summary_schema)

    def test_invalid_date_time_format(self, summary_schema):
        """Test that invalid date-time format fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "not-a-valid-datetime",
            "summary_text": "Test summary",
            "actions": [],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema, format_checker=FormatChecker())

    def test_invalid_due_date_format(self, summary_schema):
        """Test that invalid date format in due_date fails validation."""
        invalid_summary = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "summary_text": "Test summary",
            "actions": [
                {
                    "id": "act_001",
                    "description": "Do something",
                    "due_date": "not-a-valid-date"  # Must be YYYY-MM-DD
                }
            ],
            "decisions": [],
            "pipeline_version": "1.0.0",
            "model_version": "anthropic.claude-sonnet-4-20250514"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_summary, schema=summary_schema, format_checker=FormatChecker())
