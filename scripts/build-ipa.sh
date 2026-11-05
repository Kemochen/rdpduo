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
git -C "${SOURCE_DIR}" apply --check "${PROJECT_ROOT}/patches/freerdp-3.28.0-ios-openssl.patch"
git -C "${SOURCE_DIR}" apply "${PROJECT_ROOT}/patches/freerdp-3.28.0-ios-openssl.patch"

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
  done < <(grep -E -i 'CMake Error|Could NOT find|not found|No package|configure: error|error:|fatal error:' "${BUILD_LOG}" | tail -n 9)
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
APP_DIR="${PACKAGE_DIR}/Payload/DuoRDP.app"
lipo -info "${APP_DIR}/${EXECUTABLE_NAME}"

# OpenSSL's own build system records an absolute install name even though the
# surrounding CMake build uses @rpath.  That path points into the GitHub runner
# and makes dyld terminate the sideloaded app before main() is reached.  Embed
# the versioned OpenSSL libraries and rewrite every reference to the app rpath.
OPENSSL_BUILD_LIB_DIR="${BUILD_DIR}/deps/Frameworks"
APP_FRAMEWORKS_DIR="${APP_DIR}/Frameworks"
mkdir -p "${APP_FRAMEWORKS_DIR}"

openssl_library_count=0
while IFS= read -r openssl_library; do
  cp -L "${openssl_library}" "${APP_FRAMEWORKS_DIR}/$(basename "${openssl_library}")"
  openssl_library_count=$((openssl_library_count + 1))
done < <(
  find -L "${OPENSSL_BUILD_LIB_DIR}" -maxdepth 1 -type f \
    \( -name 'libssl*.dylib' -o -name 'libcrypto*.dylib' \) -print | sort -u
)

if [[ "${openssl_library_count}" -eq 0 ]]; then
  echo "::error title=OpenSSL packaging failed::No OpenSSL dylibs were found in ${OPENSSL_BUILD_LIB_DIR}"
  exit 4
fi

while IFS= read -r openssl_library; do
  install_name_tool -id "@rpath/$(basename "${openssl_library}")" "${openssl_library}"
done < <(
  find "${APP_FRAMEWORKS_DIR}" -maxdepth 1 -type f \
    \( -name 'libssl*.dylib' -o -name 'libcrypto*.dylib' \) -print
)

rewrite_openssl_dependencies() {
  local binary="$1"
  local dependency
  local library_name

  while IFS= read -r dependency; do
    case "${dependency}" in
      */libssl*.dylib|*/libcrypto*.dylib)
        library_name="$(basename "${dependency}")"
        if [[ ! -e "${APP_FRAMEWORKS_DIR}/${library_name}" ]]; then
          echo "::error title=OpenSSL packaging failed::Missing ${library_name} required by ${binary}"
          exit 4
        fi
        install_name_tool -change "${dependency}" "@rpath/${library_name}" "${binary}"
        ;;
    esac
  done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
}

rewrite_openssl_dependencies "${APP_DIR}/${EXECUTABLE_NAME}"
while IFS= read -r dylib; do
  rewrite_openssl_dependencies "${dylib}"
done < <(find "${APP_FRAMEWORKS_DIR}" -type f -name '*.dylib' -print)

missing_dependency=0
validate_macho_dependencies() {
  local binary="$1"
  local dependency
  local resolved

  while IFS= read -r dependency; do
    case "${dependency}" in
      @rpath/*)
        resolved="${APP_DIR}/Frameworks/${dependency#@rpath/}"
        ;;
      @executable_path/*)
        resolved="${APP_DIR}/${dependency#@executable_path/}"
        ;;
      @loader_path/*)
        resolved="$(dirname "${binary}")/${dependency#@loader_path/}"
        ;;
      /System/Library/*|/usr/lib/*)
        continue
        ;;
      *)
        echo "::error title=Invalid Mach-O dependency::${binary} references ${dependency}"
        missing_dependency=1
        continue
        ;;
    esac

    if [[ ! -e "${resolved}" ]]; then
      echo "::error title=Missing Mach-O dependency::${binary} requires ${dependency}"
      missing_dependency=1
    fi
  done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
}

validate_macho_dependencies "${APP_DIR}/${EXECUTABLE_NAME}"
while IFS= read -r dylib; do
  validate_macho_dependencies "${dylib}"
done < <(find "${APP_DIR}" -type f -name '*.dylib' -print)

if [[ "${missing_dependency}" -ne 0 ]]; then
  exit 4
fi

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
