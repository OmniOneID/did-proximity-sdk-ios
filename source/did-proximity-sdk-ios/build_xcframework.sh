#!/bin/bash
# Builds the XCFramework for distribution.
#
# **There is one framework** — development uses 8 SPM targets, but the XCFramework is one framework =
# one module, and apps import only the umbrella anyway. The `#if canImport(MdocProximityCore)`
# guards in the sources bridge the two (see the comment in Umbrella.swift).
#
# Not signed here. The app signs it when copying (CodeSignOnCopy).
set -xe

FRAMEWORK_NAME="MdocProximitySDK"
SCHEME_NAME="MdocProximitySDK"
FOLDER_NAME="did-proximity-sdk-ios"
PROJECT="MdocProximitySDK.xcodeproj"
CMD_BUILD="xcodebuild"

VERSION=$("$CMD_BUILD" -project "$PROJECT" -target "$SCHEME_NAME" -showBuildSettings \
          | grep MARKETING_VERSION | awk -F= '{print $2}' | xargs)

BUILD_DIR="../release/${FOLDER_NAME}-${VERSION}"
rm -rf "${BUILD_DIR}"

ARCHIVE_PATH_IOS="${BUILD_DIR}/ios.xcarchive"
ARCHIVE_PATH_IOS_SIM="${BUILD_DIR}/ios_sim.xcarchive"

# BUILD_LIBRARY_FOR_DISTRIBUTION is required — without it, apps built with another Swift version cannot link
$CMD_BUILD archive -project "$PROJECT" -scheme ${SCHEME_NAME} \
  -archivePath "$ARCHIVE_PATH_IOS" -sdk iphoneos \
  SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO
$CMD_BUILD archive -project "$PROJECT" -scheme ${SCHEME_NAME} \
  -archivePath "$ARCHIVE_PATH_IOS_SIM" -sdk iphonesimulator \
  SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO

$CMD_BUILD -create-xcframework \
  -framework "${ARCHIVE_PATH_IOS}/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework" \
  -framework "${ARCHIVE_PATH_IOS_SIM}/Products/Library/Frameworks/${FRAMEWORK_NAME}.framework" \
  -output "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"

# .abi.json embeds absolute source paths of the build machine and is only used by
# swift-api-digester; apps consume the .swiftinterface, so it is not shipped.
find "${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework" -name '*.abi.json' -delete

rm -rf "${ARCHIVE_PATH_IOS}" "${ARCHIVE_PATH_IOS_SIM}"
echo "Succeeded to create ${BUILD_DIR}/${FRAMEWORK_NAME}.xcframework"
