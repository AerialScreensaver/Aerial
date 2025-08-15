#!/bin/bash
set -e

# Aerial Unified Build Script
# Version: 4.0.0-alpha1

echo "🚀 Building Aerial 4.0.0-alpha1..."

# Configuration
PROJECT="AerialUpdater.xcodeproj"
BUILD_DIR="build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
PRODUCTS_DIR="${BUILD_DIR}/Products"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
rm -rf "$BUILD_DIR"

# Step 1: Build Aerial.saver (from Screensaver scheme)
echo -e "${YELLOW}Building Aerial.saver...${NC}"
xcodebuild -project "$PROJECT" \
           -scheme Screensaver \
           -configuration Release \
           -derivedDataPath "$DERIVED_DATA" \
           CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR" \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO

if [ ! -d "${PRODUCTS_DIR}/Aerial.saver" ]; then
    echo -e "${RED}Failed to build Aerial.saver${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Aerial.saver built successfully${NC}"

# Step 2: Build Aerial Companion.app
echo -e "${YELLOW}Building Aerial Companion.app...${NC}"
xcodebuild -project "$PROJECT" \
           -scheme "Aerial Companion" \
           -configuration Release \
           -derivedDataPath "$DERIVED_DATA" \
           CONFIGURATION_BUILD_DIR="$PRODUCTS_DIR"

if [ ! -d "${PRODUCTS_DIR}/Aerial Companion.app" ]; then
    echo -e "${RED}Failed to build Aerial Companion.app${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Aerial Companion.app built successfully${NC}"

# Step 3: Embed Aerial.saver into App Bundle
echo -e "${YELLOW}Embedding Aerial.saver into app bundle...${NC}"
SAVER_PATH="${PRODUCTS_DIR}/Aerial.saver"
APP_RESOURCES="${PRODUCTS_DIR}/Aerial Companion.app/Contents/Resources"

if [ -d "$SAVER_PATH" ]; then
    mkdir -p "$APP_RESOURCES"
    cp -R "$SAVER_PATH" "$APP_RESOURCES/"
    echo -e "${GREEN}✓ Aerial.saver successfully embedded${NC}"
else
    echo -e "${RED}Warning: Aerial.saver not found for embedding${NC}"
fi

# Verify embedded screensaver
if [ -d "${APP_RESOURCES}/Aerial.saver" ]; then
    echo -e "${GREEN}✓ Embedded screensaver verified${NC}"
else
    echo -e "${RED}Warning: Aerial.saver not found in app bundle${NC}"
fi

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Complete! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Screensaver: ${PRODUCTS_DIR}/Aerial.saver"
echo "Application: ${PRODUCTS_DIR}/Aerial Companion.app"
echo "Version: 4.0.0-alpha1"
echo ""
echo "Run the following to test:"
echo "open '${PRODUCTS_DIR}/Aerial Companion.app'"