#!/bin/zsh
set -euo pipefail

repo_root="${SRCROOT}/../.."
cli_root="${repo_root}/CLI"
configuration="${CONFIGURATION:-Debug}"
swift_configuration="debug"
if [[ "${configuration}" == "Release" ]]; then
  swift_configuration="release"
fi

current_architecture="${CURRENT_ARCH:-}"
if [[ -z "${current_architecture}" || "${current_architecture}" == "undefined_arch" ]]; then
  current_architecture="${NATIVE_ARCH_ACTUAL:-arm64}"
fi
architectures=("${current_architecture}")
if [[ "${configuration}" == "Release" ]]; then
  architectures=(arm64 x86_64)
fi

products=(agent-status-daemon agent-status-helper)
temporary_root="${DERIVED_FILE_DIR}/AgentStatusEmbeddedServices"
resource_destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
launch_agent_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"

mkdir -p "${resource_destination}" "${launch_agent_destination}" "${temporary_root}"

for product in "${products[@]}"; do
  binaries=()
  for architecture in "${architectures[@]}"; do
    scratch_path="${temporary_root}/${architecture}"
    xcrun swift build \
      --package-path "${cli_root}" \
      --scratch-path "${scratch_path}" \
      --configuration "${swift_configuration}" \
      --arch "${architecture}" \
      --product "${product}"
    binary_path="$(xcrun swift build --package-path "${cli_root}" --scratch-path "${scratch_path}" --configuration "${swift_configuration}" --arch "${architecture}" --show-bin-path)/${product}"
    binaries+=("${binary_path}")
  done

  output="${resource_destination}/${product}"
  if (( ${#binaries[@]} == 1 )); then
    ditto "${binaries[1]}" "${output}"
  else
    xcrun lipo -create "${binaries[@]}" -output "${output}"
  fi
  chmod 755 "${output}"
  if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${output}"
  fi
done

ditto \
  "${SRCROOT}/AgentStatusMac/LaunchAgents/com.huanan.AgentStatusDaemon.plist" \
  "${launch_agent_destination}/com.huanan.AgentStatusDaemon.plist"
