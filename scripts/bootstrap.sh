#!/usr/bin/env bash
set -euo pipefail
# Initialize only this Compose project's dedicated container without modifying other containers.
cd "$(dirname "$0")/.."
docker compose up -d iris
ready=0
for attempt in {1..30}; do
  if docker compose exec -T iris iris session IRIS -U USER <<< 'write "READY",!' 2>/dev/null | grep -q READY; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then printf 'IRIS_NOT_READY\n' >&2; exit 1; fi
python3 scripts/cache-embedding.py
docker compose exec -T --user 0 iris mkdir -p /durable/iris/models
docker compose cp artifacts/embedding-cache/. iris:/durable/iris/models
docker compose exec -T --user 0 iris chown -R irisowner:irisowner /durable/iris/models
output=$(docker compose exec -T iris iris session IRIS -U USER <<'IRIS'
set sc=$SYSTEM.OBJ.LoadDir("/workspace/src","ck",,1)
if $SYSTEM.Status.IsOK(sc) { do ##class(PI.Setup).Install() do ##class(PI.FHIR.Setup).Install() }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *PI_SETUP_OK* || "$output" != *PI_FHIR_SETUP_OK* || "$output" == *"Detected "*" errors"* ]]; then exit 1; fi

python3 scripts/configure-model.py

bash scripts/mcp-setup-native.sh
