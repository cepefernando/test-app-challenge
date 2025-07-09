import pytest
import json
import redis
import os
from unittest.mock import patch, MagicMock
from app import app, redis_client, COUNTER_KEY

TEST_API_KEY = 'test-api-key'

@pytest.fixture
def client():
    """Create test client."""
    app.config['TESTING'] = True
    # Set test API key
    os.environ['API_KEY'] = TEST_API_KEY
    with app.test_client() as client:
        yield client
    # Clean up
    os.environ.pop('API_KEY', None)

@pytest.fixture
def auth_headers():
    """Return headers with API key."""
    return {'X-API-Key': TEST_API_KEY}

@pytest.fixture
def mock_redis():
    """Mock Redis client."""
    with patch('app.redis_client') as mock:
        yield mock

class TestAuthentication:
    """Test cases for API key authentication."""
    
    def test_missing_api_key(self, client):
        """Test endpoints without API key."""
        # Health endpoint should work without API key
        response = client.get('/health')
        assert response.status_code == 200
        
        # Other endpoints should require API key
        endpoints = [
            ('GET', '/read'),
            ('POST', '/write'),
            ('POST', '/reset')
        ]
        for method, endpoint in endpoints:
            if method == 'GET':
                response = client.get(endpoint)
            else:
                response = client.post(endpoint)
            assert response.status_code == 401
            data = json.loads(response.data)
            assert data['error'] == 'API key required'
    
    def test_invalid_api_key(self, client):
        """Test endpoints with invalid API key."""
        headers = {'X-API-Key': 'invalid-key'}
        
        endpoints = [
            ('GET', '/read'),
            ('POST', '/write'),
            ('POST', '/reset')
        ]
        for method, endpoint in endpoints:
            if method == 'GET':
                response = client.get(endpoint, headers=headers)
            else:
                response = client.post(endpoint, headers=headers)
            assert response.status_code == 403
            data = json.loads(response.data)
            assert data['error'] == 'Invalid API key'

class TestCounterAPI:
    """Test cases for Counter API endpoints."""
    
    def test_health_endpoint_success(self, client, mock_redis):
        """Test health endpoint with successful Redis connection."""
        mock_redis.ping.return_value = True
        
        response = client.get('/health')
        assert response.status_code == 200
        
        data = json.loads(response.data)
        assert data['status'] == 'healthy'
        assert data['redis'] == 'connected'
        assert 'timestamp' in data
    
    def test_health_endpoint_redis_failure(self, client, mock_redis):
        """Test health endpoint with Redis connection failure."""
        mock_redis.ping.side_effect = redis.RedisError("Connection failed")
        
        response = client.get('/health')
        assert response.status_code == 503
        
        data = json.loads(response.data)
        assert data['status'] == 'unhealthy'
        assert data['redis'] == 'disconnected'
        assert 'error' in data
    
    def test_read_counter_new_counter(self, client, mock_redis, auth_headers):
        """Test reading counter when it doesn't exist (should initialize to 0)."""
        mock_redis.get.return_value = None
        mock_redis.set.return_value = True
        
        response = client.get('/read', headers=auth_headers)
        assert response.status_code == 200
        
        data = json.loads(response.data)
        assert data['value'] == 0
        assert 'timestamp' in data
        
        # Verify Redis operations
        mock_redis.get.assert_called_once_with(COUNTER_KEY)
        mock_redis.set.assert_called_once_with(COUNTER_KEY, 0)
    
    def test_read_counter_existing_counter(self, client, mock_redis, auth_headers):
        """Test reading existing counter value."""
        mock_redis.get.return_value = '42'
        
        response = client.get('/read', headers=auth_headers)
        assert response.status_code == 200
        
        data = json.loads(response.data)
        assert data['value'] == 42
        assert 'timestamp' in data
    
    def test_read_counter_redis_error(self, client, mock_redis, auth_headers):
        """Test reading counter with Redis error."""
        mock_redis.get.side_effect = redis.RedisError("Redis error")
        
        response = client.get('/read', headers=auth_headers)
        assert response.status_code == 503
        
        data = json.loads(response.data)
        assert data['error'] == 'Database connection error'
        assert 'timestamp' in data
    
    def test_write_counter_increment(self, client, mock_redis, auth_headers):
        """Test incrementing counter."""
        mock_redis.incr.return_value = 5
        
        response = client.post('/write', headers=auth_headers)
        assert response.status_code == 200
        
        data = json.loads(response.data)
        assert data['value'] == 5
        assert data['operation'] == 'increment'
        assert 'timestamp' in data
        
        # Verify Redis operation
        mock_redis.incr.assert_called_once_with(COUNTER_KEY)
    
    def test_write_counter_redis_error(self, client, mock_redis, auth_headers):
        """Test incrementing counter with Redis error."""
        mock_redis.incr.side_effect = redis.RedisError("Redis error")
        
        response = client.post('/write', headers=auth_headers)
        assert response.status_code == 503
        
        data = json.loads(response.data)
        assert data['error'] == 'Database connection error'
        assert 'timestamp' in data
    
    def test_reset_counter(self, client, mock_redis, auth_headers):
        """Test resetting counter to zero."""
        mock_redis.set.return_value = True
        
        response = client.post('/reset', headers=auth_headers)
        assert response.status_code == 200
        
        data = json.loads(response.data)
        assert data['value'] == 0
        assert data['operation'] == 'reset'
        assert 'timestamp' in data
        
        # Verify Redis operation
        mock_redis.set.assert_called_once_with(COUNTER_KEY, 0)
    
    def test_reset_counter_redis_error(self, client, mock_redis, auth_headers):
        """Test resetting counter with Redis error."""
        mock_redis.set.side_effect = redis.RedisError("Redis error")
        
        response = client.post('/reset', headers=auth_headers)
        assert response.status_code == 503
        
        data = json.loads(response.data)
        assert data['error'] == 'Database connection error'
        assert 'timestamp' in data
    
    def test_nonexistent_endpoint(self, client):
        """Test accessing nonexistent endpoint."""
        response = client.get('/nonexistent')
        assert response.status_code == 404
    
    def test_invalid_method(self, client):
        """Test using invalid HTTP method."""
        response = client.delete('/read')
        assert response.status_code == 405

class TestRedisConnection:
    """Test cases for Redis connection handling."""
    
    @patch('app.redis.Redis')
    def test_redis_connection_success(self, mock_redis_class):
        """Test successful Redis connection."""
        mock_client = MagicMock()
        mock_client.ping.return_value = True
        mock_redis_class.return_value = mock_client
        
        # Import and test get_redis_client
        from app import get_redis_client
        client = get_redis_client()
        
        assert client is not None
        mock_client.ping.assert_called_once()
    
    @patch('app.redis.Redis')
    @patch('app.time.sleep')
    def test_redis_connection_retry(self, mock_sleep, mock_redis_class):
        """Test Redis connection with retry logic."""
        mock_client = MagicMock()
        mock_client.ping.side_effect = [
            redis.RedisError("Connection failed"),
            redis.RedisError("Connection failed"),
            True  # Success on third try
        ]
        mock_redis_class.return_value = mock_client
        
        from app import get_redis_client
        client = get_redis_client()
        
        assert client is not None
        assert mock_client.ping.call_count == 3
        assert mock_sleep.call_count == 2
    
    @patch('app.redis.Redis')
    @patch('app.time.sleep')
    def test_redis_connection_failure(self, mock_sleep, mock_redis_class):
        """Test Redis connection failure after all retries."""
        mock_client = MagicMock()
        mock_client.ping.side_effect = redis.RedisError("Connection failed")
        mock_redis_class.return_value = mock_client
        
        from app import get_redis_client
        
        with pytest.raises(redis.RedisError):
            get_redis_client()
        
        assert mock_client.ping.call_count == 3
        assert mock_sleep.call_count == 2

class TestErrorHandling:
    """Test cases for error handling."""
    
    def test_http_exception_handler(self, client):
        """Test HTTP exception handler."""
        response = client.get('/nonexistent')
        assert response.status_code == 404
        
        data = json.loads(response.data)
        assert 'error' in data
        assert 'code' in data
        assert 'timestamp' in data
    
    def test_generic_exception_handler(self, client, mock_redis):
        """Test generic exception handler."""
        mock_redis.get.side_effect = Exception("Unexpected error")
        
        response = client.get('/read')
        assert response.status_code == 500
        
        data = json.loads(response.data)
        assert data['error'] == 'Internal server error'
        assert 'timestamp' in data

class TestIntegration:
    """Integration tests with real Redis (if available)."""
    
    def test_full_workflow_with_real_redis(self, client):
        """Test complete workflow with real Redis if available."""
        # Skip if Redis is not available
        try:
            test_redis = redis.Redis(host='localhost', port=6379, db=1)
            test_redis.ping()
        except redis.RedisError:
            pytest.skip("Redis not available for integration tests")
        
        # Clean up test data
        test_redis.delete(COUNTER_KEY)
        
        # Test read (should initialize to 0)
        response = client.get('/read')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['value'] == 0
        
        # Test write (should increment to 1)
        response = client.post('/write')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['value'] == 1
        
        # Test read again (should be 1)
        response = client.get('/read')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['value'] == 1
        
        # Test reset (should go back to 0)
        response = client.post('/reset')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['value'] == 0
        
        # Clean up
        test_redis.delete(COUNTER_KEY)

if __name__ == '__main__':
    pytest.main([__file__]) 