#!/usr/bin/env bash
set -euo pipefail
# Run the source protocol, isolated IRIS assertions, and actual native MCP bridge without paid model requests.
cd "$(dirname "$0")/.."
# Use actual port mappings for acceptance tests to avoid connecting to another local instance.
web_address=$(docker compose port iris 52773)
test_address=$(docker compose port iris 52786)
[[ "$web_address" == 127.0.0.1:* && "$test_address" == 127.0.0.1:* ]] || { printf 'TEST_PORT_INVALID\n' >&2; exit 1; }
export PI_BASE="http://$web_address" PI_URL="http://$web_address/identity" PI_TEST_MCP_URL="http://$test_address/mcp"
bash scripts/test.sh
docker compose --profile test up -d mcp-gateway-test
offline_owner="mcp-offline-$(date +%s)-$$"
offline_entered=0
cleanup() {
  if [[ "$offline_entered" == 1 ]]; then
    cleanup_output=$(docker compose exec -T -e PI_OFFLINE_OWNER="$offline_owner" iris iris session IRIS -U PITEST 2>&1 <<'IRIS'
try { set owner=$system.Util.GetEnviron("PI_OFFLINE_OWNER") if $get(^PISourceData($namespace,"maintenance"))=owner { do ##class(PI.MCP.SourceGate).LeaveMaintenance(owner) } write "TEST_CLEANUP_OK",! } catch ex { write "TEST_CLEANUP_FAILED",! }
halt
IRIS
) || cleanup_output="TEST_CLEANUP_FAILED"
    if [[ "$cleanup_output" != *TEST_CLEANUP_OK* || "$cleanup_output" == *TEST_CLEANUP_FAILED* ]]; then
      printf 'TEST_CLEANUP_FAILED: PITEST maintenance owner %s; see README for recovery.\n' "$offline_owner" >&2
    fi
  fi
  docker compose --profile test stop mcp-gateway-test >/dev/null 2>&1 || true
}
trap cleanup EXIT
output=$(docker compose exec -T iris iris session IRIS -U PITEST <<'IRIS'
write "PI_MCP_TEST_VERSION=",##class(PI.Store).Case("c1").version,!
halt
IRIS
)
printf '%s\n' "$output" | python3 -c 'import sys,re,pathlib; s=sys.stdin.read(); m=re.search(r"PI_MCP_TEST_VERSION=(\d+)",s); assert m,"Fixture version missing"; pathlib.Path("artifacts/mcp-test-version.txt").write_text(m[1])'
python3 tests/mcp_acceptance.py
python3 tests/mcp_token_acceptance.py
python3 -m unittest discover -s tests -p admin_login_acceptance.py
# Simulate source unavailability only in PITEST without interrupting the shared USER gateway.
offline_entered=1
printf 'TEST_MAINTENANCE_OWNER=%s\n' "$offline_owner"
output=$(docker compose exec -T -e PI_OFFLINE_OWNER="$offline_owner" iris iris session IRIS -U PITEST <<'IRIS'
try { do ##class(PI.MCP.SourceGate).EnterMaintenance($system.Util.GetEnviron("PI_OFFLINE_OWNER")) write "TEST_MAINTENANCE_OK",! } catch ex { write "TEST_MAINTENANCE_FAILED ",ex.Name,! }
halt
IRIS
)
[[ "$output" == *TEST_MAINTENANCE_OK* && "$output" != *TEST_MAINTENANCE_FAILED* ]] || exit 1
output=$(docker compose exec -T iris iris session IRIS -U PITEST <<'IRIS'
try { do ##class(PI.MCPTests).Offline() } catch ex { write "MCP_OFFLINE_FAILED ",ex.Name,! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *MCP_OFFLINE_OK* || "$output" == *MCP_OFFLINE_FAILED* ]]; then exit 1; fi
output=$(docker compose exec -T -e PI_OFFLINE_OWNER="$offline_owner" iris iris session IRIS -U PITEST <<'IRIS'
try { do ##class(PI.MCP.SourceGate).LeaveMaintenance($system.Util.GetEnviron("PI_OFFLINE_OWNER")) write "TEST_MAINTENANCE_RELEASED",! } catch ex { write "TEST_MAINTENANCE_RELEASE_FAILED ",ex.Name,! }
halt
IRIS
)
[[ "$output" == *TEST_MAINTENANCE_RELEASED* && "$output" != *TEST_MAINTENANCE_RELEASE_FAILED* ]] || exit 1
offline_entered=0
output=$(docker compose exec -T iris iris session IRIS -U PITEST <<'IRIS'
try { do ##class(PI.MCPDashboardTests).Metrics() do ##class(PI.MCPDashboardTests).Latest() do ##class(PI.MCPDashboardTests).Timestamps() do ##class(PI.MCPDashboardTests).AuditCallback() do ##class(PI.MCPDashboardTests).CompletionOrder() write "MCP_DASHBOARD_TESTS_OK ",^PITestCount,! } catch ex { write "MCP_DASHBOARD_TESTS_FAILED ",ex.Name,! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *MCP_DASHBOARD_TESTS_OK* || "$output" == *MCP_DASHBOARD_TESTS_FAILED* ]]; then exit 1; fi
output=$(docker compose exec -T iris iris session IRIS -U PITEST <<'IRIS'
try { do ##class(PI.MCPTokenTests).Run() } catch ex { write "MCP_TOKEN_TESTS_FAILED ",ex.Name,! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *MCP_TOKEN_TESTS_OK* || "$output" == *MCP_TOKEN_TESTS_FAILED* ]]; then exit 1; fi
