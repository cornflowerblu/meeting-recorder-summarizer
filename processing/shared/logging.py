"""
Shared Python Logging Helper
MR-20 (T013)

Provides structured JSON logging for Lambda functions with automatic PII filtering.
Integrates with CloudWatch Logs for centralized monitoring.
"""

import json
import logging
import re
import sys
from typing import Any, Dict, Optional

# PII patterns to redact
PII_PATTERNS = [
    # Email addresses
    (r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}", "[REDACTED_EMAIL]"),
    # Phone numbers
    (r"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b", "[REDACTED_PHONE]"),
    # Credit card numbers
    (r"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b", "[REDACTED_CC]"),
    # Social Security Numbers
    (r"\b\d{3}-\d{2}-\d{4}\b", "[REDACTED_SSN]"),
    # AWS Access Keys
    (r"(?:AKIA|ASIA)[0-9A-Z]{16}", "[REDACTED_AWS_KEY]"),
]

# PII keys to redact in structured data
PII_KEYS = [
    "email",
    "phone",
    "password",
    "token",
    "secret",
    "ssn",
    "credit_card",
    "access_key",
    "secret_key",
]


class StructuredLogger:
    """
    Structured JSON logger for Lambda functions.

    Usage:
        logger = StructuredLogger("my-lambda")
        logger.info("Processing started", recording_id="abc-123")
        logger.error("Upload failed", error="Network timeout", recording_id="abc-123")
    """

    def __init__(self, lambda_name: str, level: int = logging.INFO):
        """
        Initialize structured logger.

        Args:
            lambda_name: Name of the Lambda function
            level: Logging level (default: INFO)
        """
        self.lambda_name = lambda_name
        self.logger = logging.getLogger(lambda_name)
        self.logger.setLevel(level)

        # Remove existing handlers
        self.logger.handlers.clear()

        # Add CloudWatch-compatible handler
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(logging.Formatter("%(message)s"))
        self.logger.addHandler(handler)

    def _sanitize_string(self, text: str) -> str:
        """Remove PII from string."""
        sanitized = text
        for pattern, replacement in PII_PATTERNS:
            sanitized = re.sub(pattern, replacement, sanitized)
        return sanitized

    def _sanitize_dict(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Remove PII from dictionary."""
        sanitized = {}
        for key, value in data.items():
            # Check if key contains PII keyword
            if any(pii_key in key.lower() for pii_key in PII_KEYS):
                sanitized[key] = "[REDACTED]"
            elif isinstance(value, str):
                sanitized[key] = self._sanitize_string(value)
            elif isinstance(value, dict):
                sanitized[key] = self._sanitize_dict(value)
            elif isinstance(value, list):
                sanitized[key] = [
                    self._sanitize_string(item) if isinstance(item, str) else item
                    for item in value
                ]
            else:
                sanitized[key] = value
        return sanitized

    def _log(self, level: str, message: str, **kwargs: Any) -> None:
        """
        Write structured log entry.

        Args:
            level: Log level (DEBUG, INFO, WARNING, ERROR)
            message: Log message
            **kwargs: Additional structured data
        """
        # Sanitize message and data
        sanitized_message = self._sanitize_string(message)
        sanitized_data = self._sanitize_dict(kwargs)

        # Build log entry
        log_entry = {
            "level": level,
            "lambda": self.lambda_name,
            "message": sanitized_message,
            **sanitized_data,
        }

        # Convert to JSON
        log_json = json.dumps(log_entry, default=str)

        # Write to appropriate level
        if level == "DEBUG":
            self.logger.debug(log_json)
        elif level == "INFO":
            self.logger.info(log_json)
        elif level == "WARNING":
            self.logger.warning(log_json)
        elif level == "ERROR":
            self.logger.error(log_json)

    def debug(self, message: str, **kwargs: Any) -> None:
        """Log debug message."""
        self._log("DEBUG", message, **kwargs)

    def info(self, message: str, **kwargs: Any) -> None:
        """Log info message."""
        self._log("INFO", message, **kwargs)

    def warning(self, message: str, **kwargs: Any) -> None:
        """Log warning message."""
        self._log("WARNING", message, **kwargs)

    def error(self, message: str, error: Optional[Exception] = None, **kwargs: Any) -> None:
        """
        Log error message.

        Args:
            message: Error message
            error: Exception object (optional)
            **kwargs: Additional structured data
        """
        if error:
            kwargs["error_type"] = type(error).__name__
            kwargs["error_message"] = str(error)

        self._log("ERROR", message, **kwargs)


# Convenience function for quick logger creation
def get_logger(lambda_name: str, level: int = logging.INFO) -> StructuredLogger:
    """
    Get or create a structured logger.

    Args:
        lambda_name: Name of the Lambda function
        level: Logging level (default: INFO)

    Returns:
        StructuredLogger instance
    """
    return StructuredLogger(lambda_name, level)


# Example usage
if __name__ == "__main__":
    # Create logger
    logger = get_logger("example-lambda")

    # Log messages
    logger.info("Lambda invocation started", request_id="abc-123")
    logger.debug("Processing item", item_id="item-456", status="pending")
    logger.warning("Retry attempt", attempt=2, max_retries=3)
    logger.error(
        "Processing failed",
        error=Exception("Network timeout"),
        recording_id="rec-789",
    )

    # PII is automatically redacted
    logger.info(
        "User data",
        email="user@example.com",  # Will be redacted
        recording_id="rec-123",  # Will NOT be redacted
    )
