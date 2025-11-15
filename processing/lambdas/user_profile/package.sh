#!/bin/bash
# Package user_profile Lambda for deployment
# Creates deployment.zip with handler.py and all dependencies

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "📦 Packaging user_profile Lambda..."

# Clean previous package
rm -rf package deployment.zip

# Create package directory
mkdir -p package

# Install dependencies to package directory
echo "Installing dependencies..."
pip install -r requirements.txt -t package/ --quiet

# Copy handler code
echo "Copying handler..."
cp handler.py package/

# Create deployment ZIP
echo "Creating deployment.zip..."
cd package
zip -r ../deployment.zip . -q
cd ..

# Clean up package directory
rm -rf package

# Show package size
SIZE=$(du -h deployment.zip | cut -f1)
echo "✅ Package created: deployment.zip ($SIZE)"
