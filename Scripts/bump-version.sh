#!/bin/bash
set -e

# Aerial Version Bump Script
# Updates version number across the project

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="${PROJECT_ROOT}/Config/Version.xcconfig"
XCODE_PROJECT="${PROJECT_ROOT}/AerialUpdater.xcodeproj/project.pbxproj"

# Check if version argument is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: No version specified${NC}"
    echo ""
    echo "Usage: $0 <version>"
    echo "Example: $0 4.0.0alpha1"
    echo ""
    exit 1
fi

NEW_VERSION="$1"

# Validate version format (basic validation)
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo -e "${YELLOW}Warning: Version format doesn't match typical pattern (e.g., 3.9.9alpha1)${NC}"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if files exist
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}Error: Version file not found at $VERSION_FILE${NC}"
    exit 1
fi

if [ ! -f "$XCODE_PROJECT" ]; then
    echo -e "${RED}Error: Xcode project file not found at $XCODE_PROJECT${NC}"
    exit 1
fi

# Get current version
CURRENT_VERSION=$(grep "MARKETING_VERSION" "$VERSION_FILE" | awk '{print $3}')

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Aerial Version Bump${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Current version: ${CURRENT_VERSION}"
echo "New version: ${NEW_VERSION}"
echo ""

# Update Config/Version.xcconfig
echo -e "${YELLOW}Updating ${VERSION_FILE}...${NC}"
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/MARKETING_VERSION = .*/MARKETING_VERSION = ${NEW_VERSION}/" "$VERSION_FILE"
else
    # Linux
    sed -i "s/MARKETING_VERSION = .*/MARKETING_VERSION = ${NEW_VERSION}/" "$VERSION_FILE"
fi
echo -e "${GREEN}✓ Version file updated${NC}"

# Update Xcode project.pbxproj
# This updates all MARKETING_VERSION entries for Companion and Screensaver targets
echo -e "${YELLOW}Updating Xcode project...${NC}"

# Count how many will be updated (excluding AerialMusicHelper which stays at 1.0)
COUNT=$(grep -c "MARKETING_VERSION = ${CURRENT_VERSION};" "$XCODE_PROJECT" || true)

if [ "$COUNT" -gt 0 ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s/MARKETING_VERSION = ${CURRENT_VERSION};/MARKETING_VERSION = ${NEW_VERSION};/g" "$XCODE_PROJECT"
    else
        # Linux
        sed -i "s/MARKETING_VERSION = ${CURRENT_VERSION};/MARKETING_VERSION = ${NEW_VERSION};/g" "$XCODE_PROJECT"
    fi
    echo -e "${GREEN}✓ Updated ${COUNT} version entries in Xcode project${NC}"
else
    echo -e "${YELLOW}⚠ No version entries found matching '${CURRENT_VERSION}' in Xcode project${NC}"
fi

# Verify the changes
echo ""
echo -e "${YELLOW}Verifying changes...${NC}"
NEW_VERSION_CHECK=$(grep "MARKETING_VERSION" "$VERSION_FILE" | awk '{print $3}')
if [ "$NEW_VERSION_CHECK" = "$NEW_VERSION" ]; then
    echo -e "${GREEN}✓ Version file verification passed${NC}"
else
    echo -e "${RED}✗ Version file verification failed${NC}"
    exit 1
fi

XCODE_COUNT=$(grep -c "MARKETING_VERSION = ${NEW_VERSION};" "$XCODE_PROJECT" || true)
echo -e "${GREEN}✓ Found ${XCODE_COUNT} entries with new version in Xcode project${NC}"

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Version Bump Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Version updated: ${CURRENT_VERSION} → ${NEW_VERSION}"
echo ""
echo "Files modified:"
echo "  - Config/Version.xcconfig"
echo "  - AerialUpdater.xcodeproj/project.pbxproj"
echo ""
echo "Next steps:"
echo "  1. Verify the changes with: git diff"
echo "  2. Build the project to ensure everything works"
echo "  3. Commit the changes: git add Config/Version.xcconfig AerialUpdater.xcodeproj/project.pbxproj"
echo ""
