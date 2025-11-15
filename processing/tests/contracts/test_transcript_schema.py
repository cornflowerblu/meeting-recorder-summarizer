"""
Contract tests for transcript JSON schema validation.

Tests verify that transcript artifacts conform to the schema defined in
specs/001-meeting-recorder-ai/contracts/schemas/transcript.schema.json
"""

import json
import pytest
from pathlib import Path
from jsonschema import validate, ValidationError, Draft7Validator, FormatChecker


@pytest.fixture
def transcript_schema():
    """Load transcript JSON schema."""
    # Navigate from processing/tests/contracts to repo root
    schema_path = Path(__file__).parents[3] / "specs" / "001-meeting-recorder-ai" / "contracts" / "schemas" / "transcript.schema.json"
    with open(schema_path) as f:
        return json.load(f)


@pytest.fixture
def sample_transcript():
    """Load sample transcript fixture."""
    fixture_path = Path(__file__).parent.parent / "fixtures" / "sample_transcript.json"
    with open(fixture_path) as f:
        return json.load(f)


@pytest.mark.contract
class TestTranscriptSchemaValidation:
    """Test suite for transcript schema validation."""

    def test_schema_is_valid(self, transcript_schema):
        """Verify the schema itself is valid Draft 7 JSON Schema."""
        Draft7Validator.check_schema(transcript_schema)

    def test_minimal_valid_transcript(self, transcript_schema):
        """Test that a minimal valid transcript passes validation."""
        minimal_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        validate(instance=minimal_transcript, schema=transcript_schema)

    def test_complete_valid_transcript(self, transcript_schema):
        """Test that a complete transcript with all fields passes validation."""
        complete_transcript = {
            "recording_id": "rec_test456",
            "generated_at": "2025-11-15T19:00:00Z",
            "duration_ms": 180000,
            "total_segments": 3,
            "speakers_detected": 2,
            "segments": [
                {
                    "id": "seg_001",
                    "start_ms": 0,
                    "end_ms": 5000,
                    "speaker_label": "spk_0",
                    "text": "Hello everyone",
                    "confidence": 0.95,
                    "words": [
                        {
                            "word": "Hello",
                            "start_ms": 0,
                            "end_ms": 500,
                            "confidence": 0.98
                        },
                        {
                            "word": "everyone",
                            "start_ms": 500,
                            "end_ms": 1000,
                            "confidence": 0.97
                        }
                    ]
                },
                {
                    "id": "seg_002",
                    "start_ms": 6000,
                    "end_ms": 12000,
                    "speaker_label": "spk_1",
                    "text": "Good morning",
                    "confidence": 0.92
                }
            ],
            "speaker_map": {
                "spk_0": {
                    "name": "Alice",
                    "confidence": 0.90,
                    "manually_corrected": False
                },
                "spk_1": {
                    "name": "Bob",
                    "confidence": 0.88
                }
            },
            "redactions": [
                {
                    "start_ms": 30000,
                    "end_ms": 35000,
                    "reason": "Personal information",
                    "created_by": "user_123",
                    "created_at": "2025-11-15T19:05:00Z"
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        validate(instance=complete_transcript, schema=transcript_schema)

    def test_missing_required_field_recording_id(self, transcript_schema):
        """Test that missing recording_id fails validation."""
        invalid_transcript = {
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError, match="'recording_id' is a required property"):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_missing_required_field_generated_at(self, transcript_schema):
        """Test that missing generated_at fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "segments": [],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError, match="'generated_at' is a required property"):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_missing_required_field_segments(self, transcript_schema):
        """Test that missing segments fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError, match="'segments' is a required property"):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_missing_required_field_pipeline_version(self, transcript_schema):
        """Test that missing pipeline_version fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError, match="'pipeline_version' is a required property"):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_missing_required_field_model_version(self, transcript_schema):
        """Test that missing model_version fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "pipeline_version": "1.0.0"
        }
        with pytest.raises(ValidationError, match="'model_version' is a required property"):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_invalid_segment_missing_required_field(self, transcript_schema):
        """Test that segment missing required fields fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [
                {
                    "id": "seg_001",
                    "start_ms": 0,
                    "end_ms": 5000,
                    # Missing speaker_label and text
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_negative_duration_ms_fails(self, transcript_schema):
        """Test that negative duration_ms fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "duration_ms": -100,
            "segments": [],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_negative_start_ms_fails(self, transcript_schema):
        """Test that negative start_ms in segment fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [
                {
                    "id": "seg_001",
                    "start_ms": -100,
                    "end_ms": 5000,
                    "speaker_label": "spk_0",
                    "text": "Hello"
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_confidence_out_of_range_fails(self, transcript_schema):
        """Test that confidence value outside [0,1] range fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [
                {
                    "id": "seg_001",
                    "start_ms": 0,
                    "end_ms": 5000,
                    "speaker_label": "spk_0",
                    "text": "Hello",
                    "confidence": 1.5  # Invalid: > 1.0
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_transcript, schema=transcript_schema)

    def test_speaker_map_structure(self, transcript_schema):
        """Test speaker_map validation with required and optional fields."""
        transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "speaker_map": {
                "spk_0": {
                    "name": "Alice"
                    # confidence and manually_corrected are optional
                }
            },
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        validate(instance=transcript, schema=transcript_schema)

    def test_redaction_structure(self, transcript_schema):
        """Test redaction array validation with required fields."""
        transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [],
            "redactions": [
                {
                    "start_ms": 1000,
                    "end_ms": 2000
                    # reason, created_by, created_at are optional
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        validate(instance=transcript, schema=transcript_schema)

    def test_word_level_timing_structure(self, transcript_schema):
        """Test word-level timing validation in segments."""
        transcript = {
            "recording_id": "rec_test123",
            "generated_at": "2025-11-15T19:00:00Z",
            "segments": [
                {
                    "id": "seg_001",
                    "start_ms": 0,
                    "end_ms": 5000,
                    "speaker_label": "spk_0",
                    "text": "Hello world",
                    "words": [
                        {
                            "word": "Hello",
                            "start_ms": 0,
                            "end_ms": 500
                            # confidence is optional
                        },
                        {
                            "word": "world",
                            "start_ms": 500,
                            "end_ms": 1000,
                            "confidence": 0.99
                        }
                    ]
                }
            ],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        validate(instance=transcript, schema=transcript_schema)

    def test_invalid_date_time_format(self, transcript_schema):
        """Test that invalid date-time format fails validation."""
        invalid_transcript = {
            "recording_id": "rec_test123",
            "generated_at": "not-a-valid-datetime",
            "segments": [],
            "pipeline_version": "1.0.0",
            "model_version": "amazon-transcribe-2023"
        }
        with pytest.raises(ValidationError):
            validate(instance=invalid_transcript, schema=transcript_schema, format_checker=FormatChecker())
