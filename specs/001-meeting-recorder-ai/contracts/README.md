# Contracts

This folder documents machine contracts (file formats and data shapes) for the MVP. There is no public HTTP API in the MVP; the macOS app uses AWS SDKs directly.

- JSON Schemas:
  - `schemas/transcript.schema.json`
  - `schemas/summary.schema.json`
- S3 Key Conventions and DynamoDB schema are defined in `../data-model.md`.

All artifacts include `pipeline_version` and `model_version` per the constitution's transparency and versioning gates.
