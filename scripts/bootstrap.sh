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
# Disable the local demo administrator's first-login password change without altering its password or roles.
# IRIS may print exceptions to stdout, so check completion markers instead of relying only on the exit code.
output=$(docker compose exec -T iris iris session IRIS -U %SYS <<'IRIS'
try { set p("ChangePassword")=0 set sc=##class(Security.Users).Modify("_SYSTEM",.p) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } kill p set sc=##class(Security.Users).Get("_SYSTEM",.p) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } if $get(p("ChangePassword"))'=0 { throw ##class(%Exception.General).%New("ADMIN_PASSWORD_POLICY_NOT_APPLIED") } write "LOCAL_ADMIN_PASSWORD_POLICY_OK",! } catch ex { write "LOCAL_ADMIN_PASSWORD_POLICY_FAILED",! }
halt
IRIS
)
printf '%s\n' "$output"
if [[ "$output" != *LOCAL_ADMIN_PASSWORD_POLICY_OK* || "$output" == *LOCAL_ADMIN_PASSWORD_POLICY_FAILED* ]]; then exit 1; fi
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
