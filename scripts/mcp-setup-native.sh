#!/usr/bin/env bash
set -euo pipefail
# Initialize the native IRIS source service and gateways; keep credentials only in private files and Wallet.
cd "$(dirname "$0")/.."
output=$(docker compose exec -T iris iris session IRIS -U USER <<'IRIS'
try { do ##class(PI.MCP.NativeBootstrap).Provision() } catch ex { write "NATIVE_BOOTSTRAP_FAILED",! }
halt
IRIS
)
if [[ "$output" != *NATIVE_BOOTSTRAP_OK* || "$output" == *NATIVE_BOOTSTRAP_FAILED* ]]; then printf 'NATIVE_BOOTSTRAP_FAILED\n' >&2; exit 1; fi
docker compose --profile native up -d --force-recreate --no-deps native-source-user >/dev/null
for namespace in USER PITEST; do
  ready=0
  for attempt in {1..30}; do
    result=$(docker compose exec -T iris iris session IRIS -U "$namespace" <<'IRIS'
set c={"id":"c-bootstrap-probe","version":1},r={"sourceSystem":"CHECKUP","sourcePatientId":"MCP-CHECKUP-A","sourceVersion":1}
try { set a=##class(PI.MCP.NativeClient).Call(c,r,"verify_source_record") if a.status="VERIFIED" { write "SOURCE_PROBE_OK",! } } catch ex { write "SOURCE_PROBE_FAILED",! }
halt
IRIS
)
    if [[ "$result" == *SOURCE_PROBE_OK* ]]; then ready=1; break; fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then printf 'SOURCE_PROBE_FAILED %s\n' "$namespace" >&2; exit 1; fi
done
# Stop only the obsolete source-test service belonging to this Compose project after both probes pass.
iris_container=$(docker compose ps -q iris)
compose_project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$iris_container")
[[ -n "$compose_project" && "$compose_project" != '<no value>' ]] || { printf 'COMPOSE_PROJECT_UNKNOWN\n' >&2; exit 1; }
old_source_ids=$(docker ps -q --filter "label=com.docker.compose.project=$compose_project" --filter 'label=com.docker.compose.service=native-source-test')
if [[ -n "$old_source_ids" ]]; then
  while IFS= read -r old_source_id; do docker stop "$old_source_id" >/dev/null; done <<< "$old_source_ids"
fi
docker compose up -d --force-recreate --no-deps mcp-gateway >/dev/null
mkdir -p artifacts
chmod 700 artifacts
docker compose cp iris:/gateway-secret/clients/user.json artifacts/mcp-client.json >/dev/null
docker compose cp iris:/gateway-secret/clients/test.json artifacts/mcp-test-client.json >/dev/null
chmod 600 artifacts/mcp-client.json artifacts/mcp-test-client.json
user_address=$(docker compose port iris 52785)
test_address=$(docker compose port iris 52786)
if [[ "$user_address" != 127.0.0.1:* || "$test_address" != 127.0.0.1:* ]]; then printf 'CLIENT_PORT_INVALID\n' >&2; exit 1; fi
python3 scripts/rewrite-mcp-client.py artifacts/mcp-client.json "${user_address##*:}"
python3 scripts/rewrite-mcp-client.py artifacts/mcp-test-client.json "${test_address##*:}"
# Check whether the default local client credential was revoked without re-enabling it.
token_state=$(docker compose exec -T iris iris session IRIS -U USER <<'IRIS'
try { set f=##class(%Stream.FileCharacter).%New(),sc=f.LinkToFile("/gateway-secret/credentials.json"),d={}.%FromJSON(f),actor=##class(PI.MCP.Access).Validate(##class(PI.MCP.Access).Hash(d.clientToken)) write "PROBE_TOKEN_ACTIVE",! } catch ex { if ex.Name="MCP_UNAUTHORIZED" { write "PROBE_TOKEN_REVOKED",! } else { write "PROBE_TOKEN_UNKNOWN",! } }
halt
IRIS
)
if [[ "$token_state" == *PROBE_TOKEN_ACTIVE* ]]; then probe_arg=''; elif [[ "$token_state" == *PROBE_TOKEN_REVOKED* ]]; then probe_arg='--transport-only'; else printf 'PROBE_TOKEN_UNKNOWN\n' >&2; exit 1; fi
# Discover tools with valid credentials; after revocation, check transport only and report the limitation.
ready=0
for attempt in {1..30}; do
  if [[ -n "$probe_arg" ]]; then
    if python3 scripts/check-mcp-publisher.py "$probe_arg" >/dev/null 2>&1; then ready=1; break; fi
  elif python3 scripts/check-mcp-publisher.py >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then printf 'PUBLISH_GATEWAY_NOT_READY\n' >&2; exit 1; fi
if [[ -n "$probe_arg" ]]; then printf 'PUBLISH_CLIENT_REVOKED: create a new client token in MCP settings\n'; fi
printf 'NATIVE_MCP_SETUP_OK\n'
