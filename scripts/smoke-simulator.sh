#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FREERDP_REF="${FREERDP_REF:-3.28.0}"
readonly BUNDLE_ID="${DUORDP_BUNDLE_ID:-com.duordp.client}"
readonly WORK_ROOT="${PROJECT_ROOT}/.simulator-build"
readonly SOURCE_DIR="${WORK_ROOT}/FreeRDP"
readonly BUILD_DIR="${WORK_ROOT}/ios-simulator"

mkdir -p "${WORK_ROOT}"
git clone --depth 1 --branch "${FREERDP_REF}" https://github.com/FreeRDP/FreeRDP.git "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" apply "${PROJECT_ROOT}/patches/freerdp-3.28.0-iphone-duo.patch"
git -C "${SOURCE_DIR}" apply "${PROJECT_ROOT}/patches/freerdp-3.28.0-ios-openssl.patch"

cmake -S "${SOURCE_DIR}/client/iOS" -B "${BUILD_DIR}" \
  -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="${SOURCE_DIR}/cmake/ios.toolchain.cmake" \
  -DPLATFORM=SIMULATORARM64 \
  -DDEPLOYMENT_TARGET=15.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CONFIGURATION_TYPES=Release \
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

cmake --build "${BUILD_DIR}" --config Release --parallel 3

APP_PATH="$(find "${BUILD_DIR}" -type d -name 'iFreeRDP.app' -path '*Release-iphonesimulator*' -print -quit)"
if [[ -z "${APP_PATH}" ]]; then
  echo "::error title=Simulator package missing::iFreeRDP.app was not produced"
  exit 2
fi

OPENSSL_BUILD_LIB_DIR="${BUILD_DIR}/deps/Frameworks"
APP_FRAMEWORKS_DIR="${APP_PATH}/Frameworks"
mkdir -p "${APP_FRAMEWORKS_DIR}"
while IFS= read -r openssl_library; do
  cp -L "${openssl_library}" "${APP_FRAMEWORKS_DIR}/$(basename "${openssl_library}")"
done < <(
  find -L "${OPENSSL_BUILD_LIB_DIR}" -maxdepth 1 -type f \
    \( -name 'libssl*.dylib' -o -name 'libcrypto*.dylib' \) -print | sort -u
)

while IFS= read -r openssl_library; do
  install_name_tool -id "@rpath/$(basename "${openssl_library}")" "${openssl_library}"
done < <(
  find "${APP_FRAMEWORKS_DIR}" -maxdepth 1 -type f \
    \( -name 'libssl*.dylib' -o -name 'libcrypto*.dylib' \) -print
)

while IFS= read -r binary; do
  while IFS= read -r dependency; do
    case "${dependency}" in
      */libssl*.dylib|*/libcrypto*.dylib)
        library_name="$(basename "${dependency}")"
        install_name_tool -change "${dependency}" "@rpath/${library_name}" "${binary}"
        ;;
    esac
  done < <(otool -L "${binary}" | tail -n +2 | awk '{print $1}')
done < <(printf '%s\n' "${APP_PATH}/iFreeRDP"; find "${APP_FRAMEWORKS_DIR}" -type f -name '*.dylib' -print)

DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(d["udid"] for devices in data["devices"].values() for d in devices if d["name"] == "iPhone Duo" and d["isAvailable"]))')"
cleanup() {
  xcrun simctl shutdown "${DEVICE_ID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

xcrun simctl boot "${DEVICE_ID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${DEVICE_ID}" -b
xcrun simctl install "${DEVICE_ID}" "${APP_PATH}"

if ! launch_output="$(xcrun simctl launch "${DEVICE_ID}" "${BUNDLE_ID}" 2>&1)"; then
  echo "::error title=DuoRDP simulator launch failed::${launch_output}"
  exit 3
fi
echo "${launch_output}"

app_pid="${launch_output##*: }"
sleep 10
if ! kill -0 "${app_pid}" >/dev/null 2>&1; then
  xcrun simctl spawn "${DEVICE_ID}" log show --style compact --last 2m \
    --predicate 'process == "iFreeRDP" OR process == "DuoRDP"' || true
  echo "::error title=DuoRDP terminated after launch::Simulator process ${app_pid} exited during the 10-second smoke test"
  exit 4
fi

xcrun simctl terminate "${DEVICE_ID}" "${BUNDLE_ID}"
echo "DuoRDP remained running for the 10-second launch smoke test."
