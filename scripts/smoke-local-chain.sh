#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cli_root="${repo_root}/CLI"
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-smoke.XXXXXX")"
daemon_pid=""

cleanup() {
  if [[ -n "${daemon_pid}" ]]; then
    kill "${daemon_pid}" 2>/dev/null || true
    wait "${daemon_pid}" 2>/dev/null || true
  fi
  rm -rf "${smoke_root}"
}
trap cleanup EXIT INT TERM

swift build --package-path "${cli_root}"
binary_path="$(swift build --package-path "${cli_root}" --show-bin-path)"
socket_path="${smoke_root}/daemon.sock"
database_path="${smoke_root}/sessions.sqlite3"
codex_home="${smoke_root}/codex"
mkdir -p "${codex_home}/sessions"

# The helper always exits 0 (a hook exit code of 2 would block the agent's
# tool call); failures are reported on stderr only.
missing_daemon_stderr="$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"missing-daemon"}' | \
  AGENT_STATUS_SOCKET="${smoke_root}/missing.sock" "${binary_path}/agent-status-helper" 2>&1 >/dev/null)" || {
  echo "helper must exit 0 without a daemon" >&2
  exit 1
}
[[ "${missing_daemon_stderr}" == agent-status-helper:* ]]
malformed_stderr="$(printf '%s' 'not-json' | \
  AGENT_STATUS_SOCKET="${smoke_root}/missing.sock" "${binary_path}/agent-status-helper" 2>&1 >/dev/null)" || {
  echo "helper must exit 0 on malformed input" >&2
  exit 1
}
[[ "${malformed_stderr}" == agent-status-helper:* ]]

AGENT_STATUS_SUPPORT_DIRECTORY="${smoke_root}" \
AGENT_STATUS_SOCKET="${socket_path}" \
AGENT_STATUS_DATABASE="${database_path}" \
CODEX_HOME="${codex_home}" \
"${binary_path}/agent-status-daemon" 2>"${smoke_root}/daemon.log" &
daemon_pid=$!

for _ in {1..50}; do
  [[ -S "${socket_path}" ]] && break
  sleep 0.1
done
[[ -S "${socket_path}" ]]

printf '%s' '{"hook_event_name":"SessionStart","session_id":"smoke-session-0001","cwd":"/tmp/project"}' | \
  AGENT_STATUS_SOCKET="${socket_path}" "${binary_path}/agent-status-helper"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-session-0001","turn_id":"turn-1","cwd":"/tmp/project","prompt":"smoke test message"}' | \
  AGENT_STATUS_SOCKET="${socket_path}" "${binary_path}/agent-status-helper"

# A Claude session that ends before its first turn (desktop config-loading
# probe): SessionStart is retained as provisional, SessionEnd discards it.
ghost_transcript="${smoke_root}/claude/projects/-tmp-project/smoke-ghost-0001.jsonl"
printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"smoke-ghost-0001\",\"cwd\":\"/tmp/project\",\"source\":\"startup\",\"transcript_path\":\"${ghost_transcript}\"}" | \
  AGENT_STATUS_SOCKET="${socket_path}" "${binary_path}/agent-status-helper" --agent claude
ghost_provisional="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-ghost-0001";')"
[[ "${ghost_provisional}" == "1" ]]
printf '%s' "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"smoke-ghost-0001\",\"cwd\":\"/tmp/project\",\"reason\":\"other\",\"transcript_path\":\"${ghost_transcript}\"}" | \
  AGENT_STATUS_SOCKET="${socket_path}" "${binary_path}/agent-status-helper" --agent claude

session_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-session-0001";')"
timeline_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM timeline WHERE session_id = "smoke-session-0001";')"
ghost_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-ghost-0001";')"
ghost_ignored="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM ignored_sessions WHERE id = "smoke-ghost-0001";')"
[[ "${session_count}" == "1" ]]
[[ "${timeline_count}" == "2" ]]   # session_started marker + user prompt
[[ "${ghost_count}" == "0" ]]
[[ "${ghost_ignored}" == "1" ]]

echo "local-chain-smoke: session=${session_count} timeline=${timeline_count} ghost_discarded=${ghost_ignored} socket_permissions=$(stat -f %Lp "${socket_path}") helper_failures=verified"
