#!/bin/bash
set -e

# Aerial Unified Build Script
# Version: 4.0.0-alpha1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT="AerialUpdater.xcodeproj"
BUILD_CONFIG="Release"
SCREENSAVER_SCHEME="Screensaver"
SCREENSAVER_NAME="Aerial.saver"
APP_SCHEME="Aerial Companion"
APP_NAME="Aerial Companion.app"
BUILD_DIR="build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/${BUILD_CONFIG}"
PROJECT_RESOURCES="Companion/Resources"
KEYCHAIN_PROFILE="Aerial"
TEAM_ID="3L54M5L5KK"
SIGNING_IDENTITY="Developer ID Application: Guillaume Louel (3L54M5L5KK)"

# Parse command line arguments
SKIP_NOTARIZATION=true
while getopts "np:" opt; do
    case ${opt} in
        n )
            SKIP_NOTARIZATION=false
            ;;
        p )
            KEYCHAIN_PROFILE="$OPTARG"
            ;;
        \? )
            echo "Usage: $0 [-n] [-p keychain_profile]"
            echo "  -n : Enable notarization (default: skip for faster builds)"
            echo "  -p : Keychain profile name (default: Aerial)"
            exit 1
            ;;
    esac
done

# Display build configuration
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Aerial Unified Build${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Version: 4.0.0-alpha1"
echo -e "Configuration: ${BUILD_CONFIG}"
echo -e "Screensaver Scheme: ${SCREENSAVER_SCHEME}"
echo -e "App Scheme: ${APP_SCHEME}"
echo -e "Team ID: ${TEAM_ID}"
echo -e "Notarization: $([ "$SKIP_NOTARIZATION" = false ] && echo "Enabled (profile: ${KEYCHAIN_PROFILE})" || echo "Disabled")"
echo -e "${BLUE}========================================${NC}"
echo ""

# Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
if [ -d "$BUILD_DIR" ]; then
    /bin/rm -rf "$BUILD_DIR" 2>/dev/null || {
        echo -e "${YELLOW}Standard cleanup failed, trying alternative method...${NC}"
        find "$BUILD_DIR" -name ".DS_Store" -delete 2>/dev/null
        /bin/rm -rf "$BUILD_DIR"
    }
fi

# Create output directory
mkdir -p "${BUILD_DIR}/${BUILD_CONFIG}"

# ============================================
# STEP 1: Build Screensaver
# ============================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}STEP 1: Building Screensaver${NC}"
echo -e "${BLUE}========================================${NC}"

xcodebuild -project "$PROJECT" \
           -scheme "$SCREENSAVER_SCHEME" \
           -configuration "$BUILD_CONFIG" \
           -derivedDataPath "$DERIVED_DATA" \
           CODE_SIGN_STYLE="Manual" \
           CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
           DEVELOPMENT_TEAM="$TEAM_ID" \
           OTHER_CODE_SIGN_FLAGS="--timestamp" \
           | xcpretty --color || {
    # Fallback if xcpretty is not installed
    xcodebuild -project "$PROJECT" \
               -scheme "$SCREENSAVER_SCHEME" \
               -configuration "$BUILD_CONFIG" \
               -derivedDataPath "$DERIVED_DATA" \
               CODE_SIGN_STYLE="Manual" \
               CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
               DEVELOPMENT_TEAM="$TEAM_ID" \
               OTHER_CODE_SIGN_FLAGS="--timestamp"
}

# Verify screensaver build
if [ ! -d "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" ]; then
    echo -e "${RED}Failed to build ${SCREENSAVER_NAME}${NC}"
    echo -e "${RED}Expected at: ${PRODUCTS_DIR}/${SCREENSAVER_NAME}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ ${SCREENSAVER_NAME} built successfully${NC}"

# Verify code signing
echo -e "${YELLOW}Verifying code signature...${NC}"
if codesign --verify --deep --strict "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" 2>&1; then
    echo -e "${GREEN}✓ Code signature verified${NC}"

    # Check with spctl for more detailed info (non-fatal)
    echo -e "${YELLOW}Checking signature details with spctl...${NC}"
    SPCTL_OUTPUT=$(spctl -vvv --assess --type exec "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" 2>&1 || true)

    if [ -n "$SPCTL_OUTPUT" ]; then
        echo "Signature status: $SPCTL_OUTPUT"

        # Check if signed with Developer ID Application
        if echo "$SPCTL_OUTPUT" | grep -q "Developer ID Application"; then
            echo -e "${GREEN}✓ Signed with Developer ID Application certificate${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: Not signed with Developer ID Application certificate${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Could not get detailed signature information${NC}"
    fi
else
    echo -e "${RED}✗ Code signature verification failed${NC}"
    echo "This may cause notarization to fail."
fi

# ============================================
# STEP 2: Pre-copy to Resources (KEY STEP!)
# ============================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}STEP 2: Pre-copying to Resources${NC}"
echo -e "${BLUE}========================================${NC}"

# Create Resources directory if it doesn't exist
mkdir -p "${PROJECT_RESOURCES}"

# Remove existing screensaver if present to ensure clean copy
if [ -d "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}" ]; then
    echo -e "${YELLOW}Removing existing screensaver in Resources...${NC}"
    rm -rf "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}"
fi

# Copy fresh build to Resources
echo -e "${YELLOW}Copying screensaver to ${PROJECT_RESOURCES}/...${NC}"
cp -R "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" "${PROJECT_RESOURCES}/"

if [ ! -d "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}" ]; then
    echo -e "${RED}Failed to copy screensaver to project Resources${NC}"
    exit 1
fi

# Verify the copy with MD5 checksums
echo -e "${YELLOW}Verifying copy integrity with MD5...${NC}"
SOURCE_MD5=$(find "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" -type f -exec md5 -q {} \; | sort | md5 -q)
DEST_MD5=$(find "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}" -type f -exec md5 -q {} \; | sort | md5 -q)

if [ "$SOURCE_MD5" != "$DEST_MD5" ]; then
    echo -e "${RED}✗ MD5 mismatch! Copy verification failed${NC}"
    echo "Source MD5: $SOURCE_MD5"
    echo "Dest MD5: $DEST_MD5"
    exit 1
fi

echo -e "${GREEN}✓ MD5 verification passed - screensaver copied correctly${NC}"
echo -e "${GREEN}✓ Screensaver ready at: ${PROJECT_RESOURCES}/${SCREENSAVER_NAME}${NC}"

# ============================================
# STEP 3: Notarize Screensaver (if enabled)
# ============================================
if [ "$SKIP_NOTARIZATION" = false ]; then
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}STEP 3: Notarizing Screensaver${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Create zip for notarization from the fresh build in DerivedData
    SCREENSAVER_ZIP="${BUILD_DIR}/${BUILD_CONFIG}/screensaver.zip"
    echo -e "${YELLOW}Creating zip of screensaver for notarization...${NC}"
    ditto -c -k --keepParent "${PRODUCTS_DIR}/${SCREENSAVER_NAME}" "${SCREENSAVER_ZIP}"

    if [ ! -f "${SCREENSAVER_ZIP}" ]; then
        echo -e "${RED}Failed to create zip file${NC}"
        exit 1
    fi

    # Submit for notarization
    echo -e "${YELLOW}Submitting screensaver to Apple for notarization...${NC}"
    echo -e "${YELLOW}This may take several minutes...${NC}"

    # Capture notarization output
    NOTARY_OUTPUT=$(xcrun notarytool submit "${SCREENSAVER_ZIP}" \
                     --keychain-profile "${KEYCHAIN_PROFILE}" \
                     --wait 2>&1)

    # Display the output
    echo "$NOTARY_OUTPUT"

    # Extract submission ID
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -E "id: [a-f0-9-]+" | head -1 | awk '{print $2}')

    # Check for invalid or rejected status
    if echo "$NOTARY_OUTPUT" | grep -q "status: Invalid\|status: Rejected"; then
        echo ""
        echo -e "${RED}✗ Screensaver notarization failed - Status: Invalid/Rejected${NC}"
        echo ""
        if [ -n "$SUBMISSION_ID" ]; then
            echo "Submission ID: ${SUBMISSION_ID}"
            echo ""
            echo "To see why notarization failed, run:"
            echo "  xcrun notarytool log ${SUBMISSION_ID} --keychain-profile '${KEYCHAIN_PROFILE}'"
            echo ""
        fi
        echo "Common issues:"
        echo "- Missing code signature"
        echo "- Invalid or expired certificate"
        echo "- Unsigned binaries in the bundle"
        echo "- Missing entitlements"
        exit 1
    fi

    # Check if submission failed entirely
    if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        echo ""
        echo -e "${RED}✗ Screensaver notarization failed${NC}"
        echo ""
        echo "Troubleshooting tips:"
        echo "1. Ensure keychain profile '${KEYCHAIN_PROFILE}' is configured:"
        echo "   xcrun notarytool store-credentials '${KEYCHAIN_PROFILE}' \\"
        echo "   --apple-id YOUR_APPLE_ID --team-id ${TEAM_ID}"
        echo ""
        echo "2. Check notarization history:"
        echo "   xcrun notarytool history --keychain-profile '${KEYCHAIN_PROFILE}'"
        exit 1
    fi

    echo -e "${GREEN}✓ Screensaver notarization successful${NC}"

    # Staple the notarization ticket to project screensaver
    echo -e "${YELLOW}Stapling notarization ticket to screensaver...${NC}"
    if ! xcrun stapler staple "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}"; then
        echo -e "${RED}✗ Failed to staple notarization ticket${NC}"
        echo "The screensaver was notarized but stapling failed."
        echo "You may continue, but the screensaver will need internet access to verify."
        exit 1
    fi

    echo -e "${GREEN}✓ Notarization ticket stapled successfully${NC}"

    # Verify stapling
    echo -e "${YELLOW}Verifying notarization...${NC}"
    if spctl --assess --type install -vvv "${PROJECT_RESOURCES}/${SCREENSAVER_NAME}" 2>&1 | grep -q "accepted"; then
        echo -e "${GREEN}✓ Notarization verification passed${NC}"
    else
        echo -e "${YELLOW}⚠ Could not verify notarization (this may be normal for screensavers)${NC}"
    fi
else
    echo ""
    echo -e "${YELLOW}Skipping screensaver notarization (use -n flag to enable)${NC}"
fi

# ============================================
# STEP 4: Build App with Archive + Export
# ============================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}STEP 4: Building App${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Using pre-copied screensaver from ${PROJECT_RESOURCES}/${NC}"

# Archive app (like Xcode Archive)
echo -e "${YELLOW}Archiving app (${APP_SCHEME})...${NC}"
APP_ARCHIVE_PATH="${BUILD_DIR}/${BUILD_CONFIG}/${APP_NAME}.xcarchive"

xcodebuild archive \
           -project "$PROJECT" \
           -scheme "$APP_SCHEME" \
           -configuration "$BUILD_CONFIG" \
           -derivedDataPath "$DERIVED_DATA" \
           -archivePath "$APP_ARCHIVE_PATH" \
           | xcpretty --color || {
    # Fallback if xcpretty is not installed
    xcodebuild archive \
               -project "$PROJECT" \
               -scheme "$APP_SCHEME" \
               -configuration "$BUILD_CONFIG" \
               -derivedDataPath "$DERIVED_DATA" \
               -archivePath "$APP_ARCHIVE_PATH"
}

# Verify archive was created
if [ ! -d "${APP_ARCHIVE_PATH}" ]; then
    echo -e "${RED}Failed to create app archive${NC}"
    echo -e "${RED}Expected at: ${APP_ARCHIVE_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ App archive created successfully${NC}"

# Create export options plist for app distribution
APP_EXPORT_OPTIONS="${BUILD_DIR}/${BUILD_CONFIG}/AppExportOptions.plist"
cat > "$APP_EXPORT_OPTIONS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

# Export archive for distribution (like Xcode "Distribute App")
echo -e "${YELLOW}Exporting app for distribution...${NC}"
APP_EXPORT_PATH="${BUILD_DIR}/${BUILD_CONFIG}/AppExport"

xcodebuild -exportArchive \
           -archivePath "$APP_ARCHIVE_PATH" \
           -exportPath "$APP_EXPORT_PATH" \
           -exportOptionsPlist "$APP_EXPORT_OPTIONS" \
           | xcpretty --color || {
    # Fallback if xcpretty is not installed
    xcodebuild -exportArchive \
               -archivePath "$APP_ARCHIVE_PATH" \
               -exportPath "$APP_EXPORT_PATH" \
               -exportOptionsPlist "$APP_EXPORT_OPTIONS"
}

# Find the exported app
EXPORTED_APP=$(find "$APP_EXPORT_PATH" -name "*.app" -type d | head -1)
if [ ! -d "$EXPORTED_APP" ]; then
    echo -e "${RED}Failed to export app${NC}"
    echo "Export path contents:"
    ls -la "$APP_EXPORT_PATH" 2>/dev/null || echo "Export path not found"
    exit 1
fi

echo -e "${GREEN}✓ App exported successfully${NC}"
echo "Exported app: $EXPORTED_APP"

# Verify embedded screensaver in exported app
EMBEDDED_SCREENSAVER="${EXPORTED_APP}/Contents/Resources/${SCREENSAVER_NAME}"
if [ -d "$EMBEDDED_SCREENSAVER" ]; then
    echo -e "${GREEN}✓ Embedded screensaver verified in app bundle${NC}"
else
    echo -e "${RED}Warning: Embedded screensaver not found in app bundle${NC}"
fi

# ============================================
# STEP 5: Notarize App (if enabled)
# ============================================
if [ "$SKIP_NOTARIZATION" = false ]; then
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}STEP 5: Notarizing App${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Create a zip for app notarization
    echo -e "${YELLOW}Creating zip of app for notarization...${NC}"
    APP_ZIP="${BUILD_DIR}/${BUILD_CONFIG}/app.zip"
    ditto -c -k --keepParent "$EXPORTED_APP" "$APP_ZIP"

    # Submit app for notarization
    echo -e "${YELLOW}Submitting app to Apple for notarization...${NC}"
    echo -e "${YELLOW}This may take several minutes...${NC}"

    # Capture notarization output
    NOTARY_OUTPUT=$(xcrun notarytool submit "${APP_ZIP}" \
                     --keychain-profile "${KEYCHAIN_PROFILE}" \
                     --wait 2>&1)

    # Display the output
    echo "$NOTARY_OUTPUT"

    # Extract submission ID
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -E "id: [a-f0-9-]+" | head -1 | awk '{print $2}')

    # Check for invalid or rejected status
    if echo "$NOTARY_OUTPUT" | grep -q "status: Invalid\|status: Rejected"; then
        echo ""
        echo -e "${RED}✗ App notarization failed - Status: Invalid/Rejected${NC}"
        echo ""
        if [ -n "$SUBMISSION_ID" ]; then
            echo "Submission ID: ${SUBMISSION_ID}"
            echo ""
            echo "To see why notarization failed, run:"
            echo "  xcrun notarytool log ${SUBMISSION_ID} --keychain-profile '${KEYCHAIN_PROFILE}'"
            echo ""
        fi
        echo "Common issues:"
        echo "- Missing code signature"
        echo "- Invalid or expired certificate"
        echo "- Unsigned binaries in the bundle"
        echo "- Missing entitlements"
        echo "- Embedded screensaver not properly signed"
        rm "${APP_ZIP}"
        exit 1
    fi

    # Check if submission failed entirely
    if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
        echo ""
        echo -e "${RED}✗ App notarization failed${NC}"
        echo ""
        echo "The app has been built but notarization failed."
        echo "You can try notarizing manually or check your credentials."
        rm "${APP_ZIP}"
        exit 1
    fi

    echo -e "${GREEN}✓ App notarization successful${NC}"

    # Staple the notarization ticket to app
    echo -e "${YELLOW}Stapling notarization ticket to app...${NC}"
    if ! xcrun stapler staple "$EXPORTED_APP"; then
        echo -e "${RED}✗ Failed to staple notarization ticket to app${NC}"
        echo "The app was notarized but stapling failed."
        echo "Users will need internet access to verify the app on first launch."
    else
        echo -e "${GREEN}✓ Notarization ticket stapled successfully${NC}"
    fi

    # Verify notarization
    echo -e "${YELLOW}Verifying app notarization...${NC}"
    if spctl --assess --type execute -vvv "$EXPORTED_APP" 2>&1 | grep -q "accepted"; then
        echo -e "${GREEN}✓ App notarization verification passed${NC}"
    else
        echo -e "${YELLOW}⚠ Could not fully verify notarization (app may still be valid)${NC}"
    fi

    # Clean up app zip
    rm "${APP_ZIP}"
else
    echo ""
    echo -e "${YELLOW}Skipping app notarization (use -n flag to enable)${NC}"
fi

# ============================================
# STEP 6: Create Distribution Package
# ============================================
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}STEP 6: Creating Distribution Package${NC}"
echo -e "${BLUE}========================================${NC}"

FINAL_ZIP="${BUILD_DIR}/${BUILD_CONFIG}/aerial-$(date +%Y%m%d).zip"
echo -e "${YELLOW}Creating final distribution package...${NC}"
ditto -c -k --keepParent "$EXPORTED_APP" "$FINAL_ZIP"

# Get file sizes
APP_SIZE=$(du -sh "$EXPORTED_APP" | cut -f1)
ZIP_SIZE=$(du -h "$FINAL_ZIP" | cut -f1)

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Complete! 🎉${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Version: 4.0.0-alpha1"
echo "Configuration: ${BUILD_CONFIG}"
echo ""
echo "Build artifacts:"
echo "  Screensaver: ${PROJECT_RESOURCES}/${SCREENSAVER_NAME}"
echo "  Archive: ${APP_ARCHIVE_PATH}"
echo "  Exported app: ${EXPORTED_APP} (${APP_SIZE})"
echo "  Distribution package: ${FINAL_ZIP} (${ZIP_SIZE})"
echo ""
if [ "$SKIP_NOTARIZATION" = false ]; then
    echo "Notarization: ✓ Complete (both screensaver and app)"
else
    echo "Notarization: Skipped (use -n flag to enable)"
fi
echo ""
echo "To test the app, run:"
echo "  open '${EXPORTED_APP}'"
echo ""
