#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
transport_root="${repo_root}/Common/Transport"
declarations='^[[:space:]]*(public[[:space:]]+)?(struct|enum|class)[[:space:]]+(ProtocolVersion|TransportEnvelope|RequestID|DeviceID|HostID|SessionID|SessionSummary|SessionDetail|SessionLifecycle|TurnPhase|TimelineItem|RelayRoutingFrame|PairingOffer|PairingRequest|PairedDevice|RemoteSessionPayload|SessionIndexEntry|RelayHostStatus|UsageDay|UsageTokens|UsageSlice|UsageReport|UsagePricingStatus|UsageScanStatus|UsagePeriod|UsagePeriodUnit)([[:space:]:<{]|$)'

duplicates="$(rg -n --glob '*.swift' "${declarations}" "${repo_root}" --glob '!Common/Transport/**' || true)"
if [[ -n "${duplicates}" ]]; then
  echo "Transport types must be declared only in Common/Transport:"
  echo "${duplicates}"
  exit 1
fi

fixture="${transport_root}/Sources/Transport/Resources/transport-v1.json"
relay_test="${repo_root}/Relay/test/protocol.test.ts"
[[ -f "${fixture}" ]]
rg -q 'transport-v1.json' "${relay_test}"
echo "transport-boundaries: no duplicate Swift DTO declarations; Relay consumes transport-v1.json"
