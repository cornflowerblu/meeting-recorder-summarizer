# Test Fixtures

This directory contains sample data files for testing the processing pipeline.

## Files

- `sample_transcript.json` - Example transcript output from Amazon Transcribe
- `sample_summary.json` - Example summary output from Bedrock summarization

## Usage

These fixtures are used in:
- Contract tests (schema validation)
- Integration tests (end-to-end pipeline testing)
- Unit tests (individual component testing)

## Schema Compliance

All fixtures must comply with the schemas defined in `/specs/001-meeting-recorder-ai/contracts/schemas/`:
- `transcript.schema.json`
- `summary.schema.json`

Run contract tests to validate:
```bash
pytest tests/contracts/ -m contract
```
