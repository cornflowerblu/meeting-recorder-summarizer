"""
Unit tests for validate_input Lambda function (T028a)
Tests input validation logic for AI processing pipeline
"""

import pytest
from unittest.mock import patch, MagicMock
import sys
import os

# Add lambdas directory to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../lambdas/validate_input'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../'))

from handler import lambda_handler


@pytest.mark.unit
class TestValidateInput:
    """Test suite for validate_input Lambda handler"""
    
    def test_valid_input_accepted(self):
        """Test that valid input with all required fields is accepted"""
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'chunk_count': 10
        }
        context = MagicMock()
        
        result = lambda_handler(event, context)
        
        assert result['recording_id'] == 'rec_123'
        assert result['user_id'] == 'user_456'
        assert result['chunk_count'] == 10
        assert result['validated'] is True
    
    def test_missing_recording_id(self):
        """Test that missing recording_id raises ValidationError"""
        event = {
            'user_id': 'user_456',
            'chunk_count': 10
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'recording_id' in str(exc_info.value).lower()
    
    def test_missing_user_id(self):
        """Test that missing user_id raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'chunk_count': 10
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'user_id' in str(exc_info.value).lower()
    
    def test_missing_chunk_count(self):
        """Test that missing chunk_count raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456'
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'chunk_count' in str(exc_info.value).lower()
    
    def test_empty_recording_id(self):
        """Test that empty string recording_id raises ValidationError"""
        event = {
            'recording_id': '',
            'user_id': 'user_456',
            'chunk_count': 10
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'recording_id' in str(exc_info.value).lower()
    
    def test_empty_user_id(self):
        """Test that empty string user_id raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'user_id': '',
            'chunk_count': 10
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'user_id' in str(exc_info.value).lower()
    
    def test_negative_chunk_count(self):
        """Test that negative chunk_count raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'chunk_count': -5
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'chunk_count' in str(exc_info.value).lower()
    
    def test_zero_chunk_count(self):
        """Test that zero chunk_count raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'chunk_count': 0
        }
        context = MagicMock()
        
        with pytest.raises(ValueError) as exc_info:
            lambda_handler(event, context)
        
        assert 'chunk_count' in str(exc_info.value).lower()
    
    def test_non_integer_chunk_count(self):
        """Test that non-integer chunk_count raises ValidationError"""
        event = {
            'recording_id': 'rec_123',
            'user_id': 'user_456',
            'chunk_count': 'not_a_number'
        }
        context = MagicMock()
        
        with pytest.raises((ValueError, TypeError)):
            lambda_handler(event, context)
    
    def test_all_fields_missing(self):
        """Test that completely empty event raises ValidationError"""
        event = {}
        context = MagicMock()
        
        with pytest.raises(ValueError):
            lambda_handler(event, context)
