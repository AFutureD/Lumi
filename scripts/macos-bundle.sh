#!/bin/zsh
set -euo pipefail

# The single entry point for the macOS bundle artifacts:
#   macos-bundle.sh build          Xcode build phase: build, embed and sign daemon/helper
#   macos-bundle.sh verify <app>   post-archive verification before notarization

typeset -A product_identifiers=(
  Lumen app.huanan.lumi.daemon
  Spark app.huanan.lumi.helper
)
launch_agent_plist="app.huanan.lumi.daemon.plist"

build() {
  : "${SRCROOT:?build must run from the Xcode build phase}" \
    "${DERIVED_FILE_DIR:?}" "${TARGET_BUILD_DIR:?}" \
    "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}" "${CONTENTS_FOLDER_PATH:?}"
  local resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
  local launch_agents="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"

  local -a build_arguments=(
    --package-path "${SRCROOT}/../../CLI"
    --scratch-path "${DERIVED_FILE_DIR}/LumiEmbeddedServices"
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
      /usr/bin/codesign --force --options runtime --timestamp=none \
        --identifier "${identifier}" --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${resources}/${product}"
    fi
  done
  ditto "${SRCROOT}/LumiMac/LaunchAgents/${launch_agent_plist}" "${launch_agents}/${launch_agent_plist}"
}

verify() {
  local app_path="${1:-}"
  if [[ "${app_path}" != /* || ! -d "${app_path}" ]]; then
    echo "usage: ${ZSH_ARGZERO} verify /absolute/path/to/Lumi.app" >&2
    exit 64
  fi
  for product in "${(k)product_identifiers[@]}"; do
    local executable="${app_path}/Contents/Resources/${product}"
    [[ -x "${executable}" ]]
    [[ " $(lipo -archs "${executable}") " == *" arm64 "* ]]
    codesign --display --verbose "${executable}" 2>&1 | grep -q 'flags=.*(runtime)'
    codesign --verify --strict --verbose=2 "${executable}"
  done
  plutil -lint "${app_path}/Contents/Library/LaunchAgents/${launch_agent_plist}"
  codesign --verify --strict --deep --verbose=2 "${app_path}"
  spctl --assess --type execute --verbose=2 "${app_path}"
  echo "macos-bundle verify: arm64 nested executables, hardened runtime, plist, signatures, and Gatekeeper assessment passed"
}

case "${1:-}" in
  build) build ;;
  verify) verify "${2:-}" ;;
  *) echo "usage: $0 build | verify /absolute/path/to/Lumi.app" >&2; exit 64 ;;
esac
