#!/bin/bash

# Test script for Docker build verification
# This script helps verify that the Docker build works with updated dependencies

set -e

echo "Testing Docker build for js-v3.x misc protocol implementation..."

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not running"
    exit 1
fi

echo "Building Docker image with Playwright v1.55.0..."
if docker build -t libp2p-js-v3x-test .; then
    echo "✅ Docker build successful with Playwright v1.55.0"
    
    # Test that the image can start
    echo "Testing image startup..."
    if docker run --rm libp2p-js-v3x-test --version &> /dev/null; then
        echo "✅ Docker image starts successfully"
    else
        echo "⚠️  Docker image built but may have runtime issues"
    fi
else
    echo "❌ Docker build failed with Playwright v1.55.0"
    echo "Trying alternative build with Playwright v1.57.0..."
    
    if docker build -f Dockerfile.v1.57.0 -t libp2p-js-v3x-test-alt .; then
        echo "✅ Docker build successful with Playwright v1.57.0"
        echo "Consider updating the main Dockerfile to use v1.57.0"
    else
        echo "❌ Docker build failed with both Playwright versions"
        echo "Check the build logs above for specific errors"
        exit 1
    fi
fi

echo "Docker build test completed."