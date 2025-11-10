# Pipeline Versioning

We use Semantic Versioning (SemVer) for the processing pipeline and its artifacts.

- pipeline_version: MAJOR.MINOR.PATCH
- model_version: Freeform string indicating foundation model and variant (e.g., "anthropic.claude-sonnet-4.5-v2:0").

## Rules

- MAJOR: Any breaking change to artifact formats, storage layout, or observable behavior that would require a migration.
- MINOR: Backwards-compatible improvements (e.g., added fields, better quality, performance).
- PATCH: Backwards-compatible bug fixes.

## Practices

- Stamp `pipeline_version` and `model_version` in every stored artifact (transcript.json, summary.json) and the DynamoDB item.
- Maintain a `CHANGELOG.md` for pipeline changes (future work).
- For breaking changes, provide a lightweight migration script or lazy-migrate artifacts when opened by the app.
