#!/usr/bin/env bash
set -euo pipefail
# IRIS exceptions can appear on standard output; check the completion marker rather than relying only on the process exit code.
cd "$(dirname "$0")/.."
docker compose exec -T iris python3 /workspace/tests/provider_capture.py --start
trap 'docker compose exec -T iris python3 /workspace/tests/provider_capture.py --stop >/dev/null 2>&1' EXIT
output=$(docker compose exec -T iris iris session IRIS -U PITEST <<'IRIS'
set sc=$system.OBJ.LoadDir("/workspace/tests/PI","ck",,1)
if $system.Status.IsError(sc) { write "PI_TESTS_FAILED compile",! halt }
kill ^PIModels($namespace,"active")
try { set ^PITestCount=0 do ##class(PI.Tests).Isolation() do ##class(PI.Tests).Intake() do ##class(PI.Tests).Policy() do ##class(PI.Tests).Review() do ##class(PI.Tests).EvidenceLifecycle() do ##class(PI.Tests).Budget() do ##class(PI.Tests).EvidenceQuality() do ##class(PI.Tests).ReviewRegressions() do ##class(PI.Tests).Separation() do ##class(PI.Tests).LimitsAndRecovery() do ##class(PI.Phase1).Configuration() do ##class(PI.Phase1).NativePolicies() do ##class(PI.Phase1).Governance() do ##class(PI.Phase1).PolicyBoundaries() do ##class(PI.Phase1).Sessions() do ##class(PI.Phase1).ConcurrentInvestigation() do ##class(PI.Phase1).BudgetHeadroom() do ##class(PI.Phase1).LocalFailureBilling() do ##class(PI.Phase1).RestoredConfiguration() do ##class(PI.Phase1).FailureCheckpoint() do ##class(PI.Phase1).RunEvidence() do ##class(PI.ModelSettingsTests).Profiles() do ##class(PI.ModelSettingsTests).Validation() do ##class(PI.ModelSettingsTests).Pricing() do ##class(PI.ModelSettingsTests).Boundaries() do ##class(PI.ModelSettingsTests).PresetClients() do ##class(PI.NativeSourceTests).Run() do ##class(PI.NativeSourceTests).Concurrent() do ##class(PI.NativeSourceTests).GatewayConfig() do ##class(PI.NativeSourceTests).SharedGatewayConfig() do ##class(PI.NativeSourceTests).Gate() do ##class(PI.NativeSourceTests).InboundDrain() do ##class(PI.NativeSourceTests).PrivateFile() do ##class(PI.NativeSourceRemote).Run() do ##class(PI.MCPTests).SourceEvidence() do ##class(PI.MCPTests).Enrichment() do ##class(PI.MCPTests).Publishing() write "PI_TESTS_OK ",^PITestCount,! } catch ex { write "PI_TESTS_FAILED ",ex.DisplayString(),! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *PI_TESTS_OK* || "$output" == *PI_TESTS_FAILED* || "$output" == *"Detected "*" errors"* ]]; then exit 1; fi
