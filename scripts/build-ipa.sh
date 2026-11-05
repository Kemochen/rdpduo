#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FREERDP_REF="${FREERDP_REF:-3.28.0}"
readonly BUNDLE_ID="${DUORDP_BUNDLE_ID:-com.duordp.client}"
readonly WORK_ROOT="${PROJECT_ROOT}/.build"
readonly SOURCE_DIR="${WORK_ROOT}/FreeRDP"
readonly BUILD_DIR="${WORK_ROOT}/ios-device"
readonly PACKAGE_DIR="${WORK_ROOT}/package"
readonly OUTPUT_DIR="${PROJECT_ROOT}/artifacts"

if [[ -e "${SOURCE_DIR}" || -e "${BUILD_DIR}" ]]; then
  echo "Build directories already exist under ${WORK_ROOT}. Start from a clean checkout or remove .build." >&2
  exit 2
fi

mkdir -p "${WORK_ROOT}" "${OUTPUT_DIR}"

echo "Cloning FreeRDP ${FREERDP_REF}"
git clone --depth 1 --branch "${FREERDP_REF}" https://github.com/FreeRDP/FreeRDP.git "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" apply --check "${PROJECT_ROOT}/patches/freerdp-3.28.0-iphone-duo.patch"
git -C "${SOURCE_DIR}" apply "${PROJECT_ROOT}/patches/freerdp-3.28.0-iphone-duo.patch"

echo "Configuring arm64 iOS device build"
cmake -S "${SOURCE_DIR}/client/iOS" -B "${BUILD_DIR}" \
  -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="${SOURCE_DIR}/cmake/ios.toolchain.cmake" \
  -DPLATFORM=OS64 \
  -DDEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CONFIGURATION_TYPES=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DDUORDP_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DWITH_OPENSSL=ON \
  -DWITH_FFMPEG=OFF \
  -DWITH_OPENH264=OFF \
  -DWITH_CJSON=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_PNG=OFF \
  -DWITH_WEBP=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_URIPARSER=OFF

echo "Building DuoRDP"
BUILD_LOG="${WORK_ROOT}/xcode-build.log"
if ! cmake --build "${BUILD_DIR}" --config Release --parallel 3 2>&1 | tee "${BUILD_LOG}"; then
  echo "::group::DuoRDP compiler errors"
  while IFS= read -r error_line; do
    escaped="${error_line//'%'/'%25'}"
    escaped="${escaped//$'\r'/'%0D'}"
    escaped="${escaped//$'\n'/'%0A'}"
    echo "::error title=DuoRDP Xcode error::${escaped}"
  done < <(tail -n 9 "${BUILD_LOG}")
  echo "::endgroup::"
  exit 65
fi

APP_PATH="$(find "${BUILD_DIR}" -type d -name 'iFreeRDP.app' -path '*Release-iphoneos*' -print -quit)"
if [[ -z "${APP_PATH}" ]]; then
  echo "The build completed but iFreeRDP.app was not found." >&2
  find "${BUILD_DIR}" -type d -name '*.app' -print >&2
  exit 3
fi

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}/Payload"
cp -R "${APP_PATH}" "${PACKAGE_DIR}/Payload/DuoRDP.app"
rm -rf "${PACKAGE_DIR}/Payload/DuoRDP.app/_CodeSignature"
rm -f "${PACKAGE_DIR}/Payload/DuoRDP.app/embedded.mobileprovision"

plutil -replace CFBundleDisplayName -string DuoRDP \
  "${PACKAGE_DIR}/Payload/DuoRDP.app/Info.plist"

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw \
  "${PACKAGE_DIR}/Payload/DuoRDP.app/Info.plist")"
lipo -info "${PACKAGE_DIR}/Payload/DuoRDP.app/${EXECUTABLE_NAME}"

SHORT_SHA="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || printf local)"
IPA_PATH="${OUTPUT_DIR}/DuoRDP-${SHORT_SHA}.ipa"
(
  cd "${PACKAGE_DIR}"
  ditto -c -k --sequesterRsrc --keepParent Payload "${IPA_PATH}"
)

test -s "${IPA_PATH}"
echo "Created ${IPA_PATH}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "ipa_path=${IPA_PATH}" >> "${GITHUB_OUTPUT}"
fi
