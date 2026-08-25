#!/bin/zsh
set -euo pipefail

# The single entry point for Lumi's macOS bundle and release artifacts:
#   macos-bundle.sh build
#   macos-bundle.sh verify-signed /absolute/path/to/Lumi.app
#   macos-bundle.sh package-dmg /absolute/path/to/Lumi.app /absolute/path/to/Lumi.dmg [identity]
#   macos-bundle.sh verify-notarized /absolute/path/to/Lumi.app /absolute/path/to/Lumi.dmg

typeset -A product_identifiers=(
  Lumen app.huanan.lumi.daemon
  Spark app.huanan.lumi.helper
)
launch_agent_plist="app.huanan.lumi.daemon.plist"

fail() {
  echo "macos-bundle: $*" >&2
  exit 1
}

require_app() {
  local app_path="$1"
  [[ "${app_path}" == /* && -d "${app_path}" ]] || fail "expected an absolute .app path: ${app_path}"
  [[ -x "${app_path}/Contents/MacOS/Lumi" ]] || fail "missing Lumi executable in ${app_path}"
}

build() {
  : "${SRCROOT:?build must run from the Xcode build phase}" \
    "${DERIVED_FILE_DIR:?}" "${TARGET_BUILD_DIR:?}" \
    "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}" "${CONTENTS_FOLDER_PATH:?}"
  local resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
  local launch_agents="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"

  local -a build_arguments=(
    --package-path "${SRCROOT}/../../CLI"
    --scratch-path "${DERIVED_FILE_DIR}/LumiEmbeddedServices"
    --arch arm64
  )
  if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
    build_arguments+=(--configuration release)
  fi
  xcrun swift build "${build_arguments[@]}"
  local bin_path="$(xcrun swift build "${build_arguments[@]}" --show-bin-path)"

  mkdir -p "${resources}" "${launch_agents}"
  for product identifier in "${(kv)product_identifiers[@]}"; do
    ditto "${bin_path}/${product}" "${resources}/${product}"
    if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
      strip -Sx "${resources}/${product}"
    fi
    if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
      local identity_name="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-${CODE_SIGN_IDENTITY:-}}"
      local timestamp_option="--timestamp=none"
      if [[ "${identity_name}" == "Developer ID Application"* ]]; then
        timestamp_option="--timestamp"
      fi
      /usr/bin/codesign --force --options runtime "${timestamp_option}" \
        --identifier "${identifier}" --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${resources}/${product}"
    fi
  done
  ditto "${SRCROOT}/LumiMac/LaunchAgents/${launch_agent_plist}" "${launch_agents}/${launch_agent_plist}"
}

verify_developer_id_signature() {
  local code_path="$1"
  local requires_runtime="${2:-yes}"
  local expected_team="$3"
  local details="$(codesign --display --verbose=4 "${code_path}" 2>&1)"
  [[ "${details}" == *"Authority=Developer ID Application:"* ]] || fail "not Developer ID signed: ${code_path}"
  [[ "${details}" == *"TeamIdentifier=${expected_team}"* ]] || fail "unexpected signing team: ${code_path}"
  [[ "${details}" == *$'\nTimestamp='* ]] || fail "secure timestamp missing: ${code_path}"
  if [[ "${requires_runtime}" == yes ]]; then
    [[ "${details}" == *"flags="*"runtime"* ]] || fail "Hardened Runtime missing: ${code_path}"
  fi
  codesign --verify --strict --verbose=2 "${code_path}"
}

verify_signed() {
  local app_path="$1"
  require_app "${app_path}"
  [[ -n "${EXPECTED_TEAM_ID:-}" ]] || fail "EXPECTED_TEAM_ID must name the Developer ID team to verify against"
  local expected_team="${EXPECTED_TEAM_ID}"

  for product in "${(k)product_identifiers[@]}"; do
    local executable="${app_path}/Contents/Resources/${product}"
    [[ -x "${executable}" ]] || fail "missing embedded executable: ${product}"
    [[ " $(lipo -archs "${executable}") " == *" arm64 "* ]] || fail "${product} is not arm64"
  done
  plutil -lint "${app_path}/Contents/Library/LaunchAgents/${launch_agent_plist}"
  codesign --verify --strict --deep --verbose=2 "${app_path}"
  verify_developer_id_signature "${app_path}" yes "${expected_team}"

  local executable
  while IFS= read -r executable; do
    if [[ "$(file -b "${executable}")" == *"Mach-O"* ]]; then
      verify_developer_id_signature "${executable}" yes "${expected_team}"
    fi
  done < <(find "${app_path}/Contents" -type f -print)

  echo "macos-bundle verify-signed: Developer ID, timestamps, Hardened Runtime, nested code, plist, and arm64 services passed"
}

package_dmg() {
  local app_path="$1"
  local dmg_path="$2"
  local identity="${3:-Developer ID Application}"
  require_app "${app_path}"
  [[ "${dmg_path}" == /* && "${dmg_path}" == *.dmg ]] || fail "expected an absolute .dmg output path"

  local staging="$(mktemp -d "${TMPDIR%/}/lumi-dmg.XXXXXX")"
  local result_code=0
  (
    set -e
    ditto "${app_path}" "${staging}/Lumi.app"
    ln -s /Applications "${staging}/Applications"
    mkdir -p "${dmg_path:h}"
    hdiutil create -volname Lumi -srcfolder "${staging}" -ov -format UDZO "${dmg_path}"
    codesign --force --timestamp --sign "${identity}" "${dmg_path}"
  ) || result_code=$?
  rm -rf -- "${staging}"
  (( result_code == 0 )) || return "${result_code}"
  echo "macos-bundle package-dmg: ${dmg_path}"
}

verify_notarized() {
  local app_path="$1"
  local dmg_path="$2"
  require_app "${app_path}"
  [[ "${dmg_path}" == /* && -f "${dmg_path}" ]] || fail "expected an existing absolute .dmg path"
  [[ -n "${EXPECTED_TEAM_ID:-}" ]] || fail "EXPECTED_TEAM_ID must name the Developer ID team to verify against"
  local expected_team="${EXPECTED_TEAM_ID}"

  xcrun stapler validate "${app_path}"
  xcrun stapler validate "${dmg_path}"
  codesign --verify --strict --deep --verbose=2 "${app_path}"
  verify_developer_id_signature "${dmg_path}" no "${expected_team}"
  spctl --assess --type execute --verbose=2 "${app_path}"
  spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg_path}"

  local mount_point="$(mktemp -d "${TMPDIR%/}/lumi-mount.XXXXXX")"
  local result_code=0
  (
    set -e
    trap 'hdiutil detach "'"${mount_point}"'" >/dev/null 2>&1 || true' EXIT
    hdiutil attach -readonly -nobrowse -mountpoint "${mount_point}" "${dmg_path}" >/dev/null
    xcrun stapler validate "${mount_point}/Lumi.app"
    codesign --verify --strict --deep --verbose=2 "${mount_point}/Lumi.app"
    spctl --assess --type execute --verbose=2 "${mount_point}/Lumi.app"
  ) || result_code=$?
  rm -rf -- "${mount_point}"
  (( result_code == 0 )) || return "${result_code}"
  echo "macos-bundle verify-notarized: App and DMG tickets, signatures, Gatekeeper, and mounted App passed"
}

case "${1:-}" in
  build) build ;;
  verify-signed) verify_signed "${2:-}" ;;
  package-dmg) package_dmg "${2:-}" "${3:-}" "${4:-Developer ID Application}" ;;
  verify-notarized) verify_notarized "${2:-}" "${3:-}" ;;
  *)
    echo "usage: $0 build | verify-signed /absolute/Lumi.app | package-dmg /absolute/Lumi.app /absolute/Lumi.dmg [identity] | verify-notarized /absolute/Lumi.app /absolute/Lumi.dmg" >&2
    exit 64
    ;;
esac
