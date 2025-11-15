"""
Configuration Management for Lambda Functions
MR-22 (T015)

Centralized configuration loading from environment variables.
"""

import os
from typing import Optional
from functools import lru_cache


class Config:
    """
    Configuration manager for Lambda functions.

    Loads configuration from environment variables with sensible defaults.
    """

    # AWS Configuration
    AWS_REGION: str = os.environ.get("AWS_REGION", "us-east-1")
    S3_BUCKET_NAME: str = os.environ.get("S3_BUCKET_NAME", "")
    DYNAMODB_TABLE_NAME: str = os.environ.get("DYNAMODB_TABLE_NAME", "")

    # Authentication
    MACOS_APP_ROLE_ARN: str = os.environ.get("MACOS_APP_ROLE_ARN", "")
    SESSION_DURATION: int = int(os.environ.get("SESSION_DURATION", "3600"))

    # Processing
    TRANSCRIBE_LANGUAGE_CODE: str = os.environ.get("TRANSCRIBE_LANGUAGE_CODE", "en-US")
    TRANSCRIBE_SERVICE_ROLE_ARN: str = os.environ.get("TRANSCRIBE_SERVICE_ROLE_ARN", "")
    BEDROCK_MODEL_ID: str = os.environ.get(
        "BEDROCK_MODEL_ID", "anthropic.claude-sonnet-4-20250514"
    )
    BEDROCK_MAX_TOKENS: int = int(os.environ.get("BEDROCK_MAX_TOKENS", "4096"))

    # Step Functions
    STATE_MACHINE_ARN: str = os.environ.get("STATE_MACHINE_ARN", "")

    # Pipeline Versioning
    PIPELINE_VERSION: str = os.environ.get("PIPELINE_VERSION", "1.0.0")

    # Logging
    LOG_LEVEL: str = os.environ.get("LOG_LEVEL", "INFO")
    ENABLE_DETAILED_LOGGING: bool = os.environ.get("ENABLE_DETAILED_LOGGING", "false").lower() == "true"

    # Cost Estimation (per-hour rates in USD)
    TRANSCRIBE_COST_PER_HOUR: float = float(os.environ.get("TRANSCRIBE_COST_PER_HOUR", "0.72"))
    BEDROCK_COST_PER_1K_INPUT_TOKENS: float = float(
        os.environ.get("BEDROCK_COST_PER_1K_INPUT_TOKENS", "0.003")
    )
    BEDROCK_COST_PER_1K_OUTPUT_TOKENS: float = float(
        os.environ.get("BEDROCK_COST_PER_1K_OUTPUT_TOKENS", "0.015")
    )
    S3_STORAGE_COST_PER_GB_MONTH: float = float(
        os.environ.get("S3_STORAGE_COST_PER_GB_MONTH", "0.023")
    )

    # Feature Flags
    ENABLE_CUSTOM_VOCABULARY: bool = (
        os.environ.get("ENABLE_CUSTOM_VOCABULARY", "false").lower() == "true"
    )
    ENABLE_SPEAKER_DIARIZATION: bool = (
        os.environ.get("ENABLE_SPEAKER_DIARIZATION", "true").lower() == "true"
    )
    ENABLE_COST_ESTIMATION: bool = (
        os.environ.get("ENABLE_COST_ESTIMATION", "true").lower() == "true"
    )

    @classmethod
    def validate(cls) -> None:
        """
        Validate required configuration is present.

        Raises:
            ValueError: If required configuration is missing
        """
        required = {
            "S3_BUCKET_NAME": cls.S3_BUCKET_NAME,
            "DYNAMODB_TABLE_NAME": cls.DYNAMODB_TABLE_NAME,
            "AWS_REGION": cls.AWS_REGION,
        }

        missing = [key for key, value in required.items() if not value]

        if missing:
            raise ValueError(f"Missing required configuration: {', '.join(missing)}")

    @classmethod
    def get(cls, key: str, default: Optional[str] = None) -> Optional[str]:
        """
        Get configuration value.

        Args:
            key: Configuration key
            default: Default value if not found

        Returns:
            Configuration value or default
        """
        return os.environ.get(key, default)

    @classmethod
    def get_int(cls, key: str, default: int = 0) -> int:
        """
        Get integer configuration value.

        Args:
            key: Configuration key
            default: Default value if not found or invalid

        Returns:
            Configuration value or default
        """
        try:
            return int(os.environ.get(key, str(default)))
        except ValueError:
            return default

    @classmethod
    def get_float(cls, key: str, default: float = 0.0) -> float:
        """
        Get float configuration value.

        Args:
            key: Configuration key
            default: Default value if not found or invalid

        Returns:
            Configuration value or default
        """
        try:
            return float(os.environ.get(key, str(default)))
        except ValueError:
            return default

    @classmethod
    def get_bool(cls, key: str, default: bool = False) -> bool:
        """
        Get boolean configuration value.

        Args:
            key: Configuration key
            default: Default value if not found

        Returns:
            Configuration value or default
        """
        value = os.environ.get(key, str(default)).lower()
        return value in ("true", "1", "yes", "on")


@lru_cache(maxsize=1)
def get_config() -> Config:
    """
    Get configuration instance.

    Returns:
        Config instance
    """
    return Config()  # pass any required constructor args here


# Example usage
if __name__ == "__main__":
    # Validate configuration
    try:
        Config.validate()
        print("Configuration valid!")
    except ValueError as e:
        print(f"Configuration error: {e}")

    # Access configuration
    print(f"AWS Region: {Config.AWS_REGION}")
    print(f"S3 Bucket: {Config.S3_BUCKET_NAME}")
    print(f"DynamoDB Table: {Config.DYNAMODB_TABLE_NAME}")
    print(f"Transcribe Language: {Config.TRANSCRIBE_LANGUAGE_CODE}")
    print(f"Bedrock Model: {Config.BEDROCK_MODEL_ID}")
