#!/usr/bin/env python3
"""
Counter API Service
A simple REST API that increments a counter stored in Redis.
"""

import os
import logging
import redis
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException
import time

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration
REDIS_HOST = os.getenv('REDIS_HOST', 'localhost')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_DB = int(os.getenv('REDIS_DB', 0))
REDIS_PASSWORD = os.getenv('REDIS_PASSWORD', None)
COUNTER_KEY = 'api_counter'
MAX_RETRIES = 3
RETRY_DELAY = 0.5

# Initialize Redis connection with retry logic
def get_redis_client():
    """Get Redis client with connection retry logic."""
    for attempt in range(MAX_RETRIES):
        try:
            client = redis.Redis(
                host=REDIS_HOST,
                port=REDIS_PORT,
                db=REDIS_DB,
                password=REDIS_PASSWORD,
                decode_responses=True,
                socket_timeout=5,
                socket_connect_timeout=5,
                retry_on_timeout=True
            )
            # Test connection
            client.ping()
            logger.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
            return client
        except redis.RedisError as e:
            logger.warning(f"Redis connection attempt {attempt + 1} failed: {e}")
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_DELAY)
            else:
                logger.error("Failed to connect to Redis after all retries")
                raise

redis_client = get_redis_client()

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint for Kubernetes liveness/readiness probes."""
    try:
        # Check Redis connection
        redis_client.ping()
        return jsonify({
            'status': 'healthy',
            'redis': 'connected',
            'timestamp': time.time()
        }), 200
    except redis.RedisError as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'redis': 'disconnected',
            'error': str(e),
            'timestamp': time.time()
        }), 503

@app.route('/read', methods=['GET'])
def read_counter():
    """Read the current counter value from Redis."""
    try:
        logger.info("Reading counter value")
        value = redis_client.get(COUNTER_KEY)
        
        if value is None:
            # Initialize counter if it doesn't exist
            redis_client.set(COUNTER_KEY, 0)
            value = 0
        else:
            value = int(value)
        
        logger.info(f"Counter value read: {value}")
        return jsonify({
            'value': value,
            'timestamp': time.time()
        }), 200
        
    except redis.RedisError as e:
        logger.error(f"Redis error during read: {e}")
        return jsonify({
            'error': 'Database connection error',
            'timestamp': time.time()
        }), 503
    except Exception as e:
        logger.error(f"Unexpected error during read: {e}")
        return jsonify({
            'error': 'Internal server error',
            'timestamp': time.time()
        }), 500

@app.route('/write', methods=['POST'])
def write_counter():
    """Increment the counter value in Redis."""
    try:
        logger.info("Incrementing counter value")
        
        # Use Redis atomic increment operation
        new_value = redis_client.incr(COUNTER_KEY)
        
        logger.info(f"Counter incremented to: {new_value}")
        return jsonify({
            'value': new_value,
            'operation': 'increment',
            'timestamp': time.time()
        }), 200
        
    except redis.RedisError as e:
        logger.error(f"Redis error during write: {e}")
        return jsonify({
            'error': 'Database connection error',
            'timestamp': time.time()
        }), 503
    except Exception as e:
        logger.error(f"Unexpected error during write: {e}")
        return jsonify({
            'error': 'Internal server error',
            'timestamp': time.time()
        }), 500

@app.route('/reset', methods=['POST'])
def reset_counter():
    """Reset the counter to zero (useful for testing)."""
    try:
        logger.info("Resetting counter value")
        redis_client.set(COUNTER_KEY, 0)
        
        logger.info("Counter reset to 0")
        return jsonify({
            'value': 0,
            'operation': 'reset',
            'timestamp': time.time()
        }), 200
        
    except redis.RedisError as e:
        logger.error(f"Redis error during reset: {e}")
        return jsonify({
            'error': 'Database connection error',
            'timestamp': time.time()
        }), 503
    except Exception as e:
        logger.error(f"Unexpected error during reset: {e}")
        return jsonify({
            'error': 'Internal server error',
            'timestamp': time.time()
        }), 500

@app.errorhandler(HTTPException)
def handle_http_exception(e):
    """Handle HTTP exceptions with proper JSON responses."""
    logger.warning(f"HTTP error: {e}")
    return jsonify({
        'error': e.description,
        'code': e.code,
        'timestamp': time.time()
    }), e.code

@app.errorhandler(Exception)
def handle_generic_exception(e):
    """Handle unexpected exceptions."""
    logger.error(f"Unhandled exception: {e}")
    return jsonify({
        'error': 'Internal server error',
        'timestamp': time.time()
    }), 500

if __name__ == '__main__':
    port = int(os.getenv('PORT', 5000))
    debug = os.getenv('DEBUG', 'false').lower() == 'true'
    
    logger.info(f"Starting Counter API on port {port}")
    logger.info(f"Redis connection: {REDIS_HOST}:{REDIS_PORT}")
    
    app.run(host='0.0.0.0', port=port, debug=debug) 