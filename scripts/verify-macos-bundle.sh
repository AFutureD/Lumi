#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 /absolute/path/to/Lumi.app" >&2
  exit 64
fi

app_path="$1"
if [[ "${app_path}" != /* || ! -d "${app_path}" ]]; then
  echo "expected an existing absolute .app path" >&2
  exit 64
fi

daemon_path="${app_path}/Contents/Resources/Lumen"
helper_path="${app_path}/Contents/Resources/Spark"
launch_agent_path="${app_path}/Contents/Library/LaunchAgents/app.huanan.lumi.daemon.plist"

for executable in "${daemon_path}" "${helper_path}"; do
  [[ -x "${executable}" ]]
  architectures="$(lipo -archs "${executable}")"
  [[ " ${architectures} " == *" arm64 "* ]]
  [[ " ${architectures} " == *" x86_64 "* ]]
  codesign --verify --strict --verbose=2 "${executable}"
done

plutil -lint "${launch_agent_path}"
codesign --verify --strict --deep --verbose=2 "${app_path}"
spctl --assess --type execute --verbose=2 "${app_path}"
echo "macos-bundle-verification: universal nested executables, plist, signatures, and Gatekeeper assessment passed"
