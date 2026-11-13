#!/usr/bin/env bash
set -euo pipefail
# Run real Production/HTTP tests in a fresh instance with no external network or shared data volume.
cd "$(dirname "$0")/.."
name="pi-notify-smoke-$(date +%s)-$$"
mkdir -p artifacts/notification-smoke
log="artifacts/notification-smoke/$name.log"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" --network none -v "$PWD:/workspace:ro" \
    "${IRIS_IMAGE:-iris-community:2026.3.0AI.154.0}" > /dev/null
ready=0
for attempt in {1..40}; do
    if docker exec -i "$name" iris session IRIS -U USER <<< 'write "NOTIFY_READY",!' 2>/dev/null | grep -q NOTIFY_READY; then ready=1; break; fi
    sleep 1
done
[[ "$ready" == 1 ]] || { echo NOTIFY_INSTANCE_NOT_READY >&2; exit 1; }
docker exec "$name" python3 -m unittest discover -s /workspace/tests -p test_mock_his.py -v 2>&1 | tee "$log"
docker exec -d "$name" python3 /workspace/tests/mock_his.py --database /tmp/pi-mock-his.sqlite
output=$(docker exec -i "$name" iris session IRIS -U USER <<'IRIS'
try { set sc=##class(%EnsembleMgr).EnableNamespace("USER") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } set sc=$system.OBJ.LoadDir("/workspace/src","ck",,1) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } for file="Tests","NotificationProduction" { set sc=$system.OBJ.Load("/workspace/tests/PI/"_file_".cls","ck") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } } set sc=##class(Ens.Director).StartProduction("PI.NotificationProduction") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } write "NOTIFY_PRODUCTION_READY",! } catch ex { write "NOTIFY_SETUP_FAILED ",ex.DisplayString(),! }
halt
IRIS
)
printf '%s\n' "$output" >> "$log"
[[ "$output" == *NOTIFY_PRODUCTION_READY* && "$output" != *NOTIFY_SETUP_FAILED* && "$output" != *"Detected "*" errors"* ]] || { tail -40 "$log"; exit 1; }
PI_NOTIFICATION_CONTAINER="$name" python3 -m unittest discover -s tests -p test_notification_native.py -v 2>&1 | tee -a "$log"
echo "NOTIFICATION_SMOKE_OK log=$log" | tee -a "$log"
