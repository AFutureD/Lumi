#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
version_config="${repo_root}/Config/Version.xcconfig"

read_setting() {
  local name="$1"
  awk -F '=' -v key="${name}" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${version_config}"
}

marketing_version="$(read_setting MARKETING_VERSION)"
build_version="$(read_setting CURRENT_PROJECT_VERSION)"

[[ "${marketing_version}" == <->.<->(|.<->) ]] || {
  echo "release-version: MARKETING_VERSION must be numeric major.minor[.patch]" >&2
  exit 1
}
[[ "${build_version}" == <-> && "${build_version}" -gt 0 ]] || {
  echo "release-version: CURRENT_PROJECT_VERSION must be a positive integer" >&2
  exit 1
}

case "${1:-}" in
  show)
    echo "version=${marketing_version}"
    echo "build=${build_version}"
    ;;
  validate)
    tag="${2:-}"
    appcast_path="${3:-}"
    [[ "${tag}" == "v${marketing_version}" ]] || {
      echo "release-version: tag ${tag:-<missing>} must equal v${marketing_version}" >&2
      exit 1
    }
    if [[ -n "${appcast_path}" && -f "${appcast_path}" ]]; then
      previous_build="$(xmllint --xpath 'string((//*[local-name()="item"]/*[local-name()="version"])[1])' "${appcast_path}")"
      [[ -z "${previous_build}" || "${previous_build}" == <-> ]] || {
        echo "release-version: previous Sparkle build is not an integer: ${previous_build}" >&2
        exit 1
      }
      [[ -z "${previous_build}" || "${build_version}" -gt "${previous_build}" ]] || {
        echo "release-version: build ${build_version} must be greater than published build ${previous_build}" >&2
        exit 1
      }
    fi
    echo "version=${marketing_version}"
    echo "build=${build_version}"
    ;;
  *)
    echo "usage: $0 show | validate <tag> [previous-appcast.xml]" >&2
    exit 64
    ;;
esac
