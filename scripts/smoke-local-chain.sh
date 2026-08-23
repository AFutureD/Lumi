#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
cli_root="${repo_root}/CLI"
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/lumi-smoke.XXXXXX")"
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
log_directory="${smoke_root}/logs"
missing_daemon_stderr="$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"missing-daemon"}' | \
  LUMI_SOCKET="${smoke_root}/missing.sock" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark" 2>&1 >/dev/null)" || {
  echo "helper must exit 0 without a daemon" >&2
  exit 1
}
[[ "${missing_daemon_stderr}" == Spark:* ]]
malformed_stderr="$(printf '%s' 'not-json' | \
  LUMI_SOCKET="${smoke_root}/missing.sock" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark" 2>&1 >/dev/null)" || {
  echo "helper must exit 0 on malformed input" >&2
  exit 1
}
[[ "${malformed_stderr}" == Spark:* ]]

# Logs go next to the smoke database, never into ~/Library/Logs/Lumi.
LUMI_SUPPORT_DIRECTORY="${smoke_root}" \
LUMI_SOCKET="${socket_path}" \
LUMI_DATABASE="${database_path}" \
LUMI_LOG_DIRECTORY="${log_directory}" \
LUMI_LOG_LEVEL="debug" \
CODEX_HOME="${codex_home}" \
"${binary_path}/Lumen" 2>"${smoke_root}/daemon.stderr" &
daemon_pid=$!

for _ in {1..50}; do
  [[ -S "${socket_path}" ]] && break
  sleep 0.1
done
[[ -S "${socket_path}" ]]

printf '%s' '{"hook_event_name":"SessionStart","session_id":"smoke-session-0001","cwd":"/tmp/project"}' | \
  LUMI_SOCKET="${socket_path}" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"smoke-session-0001","turn_id":"turn-1","cwd":"/tmp/project","prompt":"smoke test message"}' | \
  LUMI_SOCKET="${socket_path}" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark"

# A Claude session that ends before its first turn (desktop config-loading
# probe): SessionStart is retained as provisional, SessionEnd discards it.
ghost_transcript="${smoke_root}/claude/projects/-tmp-project/smoke-ghost-0001.jsonl"
printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"smoke-ghost-0001\",\"cwd\":\"/tmp/project\",\"source\":\"startup\",\"transcript_path\":\"${ghost_transcript}\"}" | \
  LUMI_SOCKET="${socket_path}" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark" --agent claude
ghost_provisional="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-ghost-0001";')"
[[ "${ghost_provisional}" == "1" ]]
printf '%s' "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"smoke-ghost-0001\",\"cwd\":\"/tmp/project\",\"reason\":\"other\",\"transcript_path\":\"${ghost_transcript}\"}" | \
  LUMI_SOCKET="${socket_path}" LUMI_LOG_DIRECTORY="${log_directory}" "${binary_path}/Spark" --agent claude

session_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-session-0001";')"
timeline_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM timeline WHERE session_id = "smoke-session-0001";')"
ghost_count="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM sessions WHERE id = "smoke-ghost-0001";')"
ghost_ignored="$(/usr/bin/sqlite3 "${database_path}" 'SELECT COUNT(*) FROM ignored_sessions WHERE id = "smoke-ghost-0001";')"
[[ "${session_count}" == "1" ]]
[[ "${timeline_count}" == "2" ]]   # session_started marker + user prompt
[[ "${ghost_count}" == "0" ]]
[[ "${ghost_ignored}" == "1" ]]

# Logging: the daemon announced itself and the ingest, the helper recorded
# its hook runs, the missing-daemon failures landed in errors.log, and no
# session content (the prompt text) leaked into any log file.
grep -q '\] \[INFO:daemon\] \[lifecycle\] daemon_started ' "${log_directory}/daemon.log"
grep -Eq "\] \[INFO:daemon\] \[agent\] \['trace':[^]]+\] events_ingested " "${log_directory}/daemon.log"
grep -Eq "\] \[DEBUG:daemon\] \[ipc\] \['trace':[^]]+\] ipc_handled .*op=ingest_batch" "${log_directory}/daemon.log"
grep -Eq "\] \[INFO:helper\] \[agent\] \['trace':[^]]+\] hook_ingested .*hook=UserPromptSubmit .*provider=codex .*session=smoke-session-0001" "${log_directory}/helper.log"
grep -q '\] \[ERROR:helper\] \[agent\] ' "${log_directory}/errors.log"
! grep -rq 'smoke test message' "${log_directory}"
# The helper's run id is the IPC request id: the daemon's lines for that hook carry the same trace.
helper_trace="$(grep -Eo "\['trace':[^]]+\] hook_ingested .*hook=UserPromptSubmit" "${log_directory}/helper.log" | head -1 | sed -E "s/^\['trace':([^]]+)\].*/\1/")"
[[ -n "${helper_trace}" ]]
grep -q "\['trace':${helper_trace}\] ipc_handled " "${log_directory}/daemon.log"

echo "local-chain-smoke: session=${session_count} timeline=${timeline_count} ghost_discarded=${ghost_ignored} socket_permissions=$(stat -f %Lp "${socket_path}") helper_failures=verified logs=verified"
