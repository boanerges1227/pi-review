#!/usr/bin/env bash
set -euo pipefail
# Use a new loopback-only instance; never read application credentials or use an existing data volume.
cd "$(dirname "$0")/.."
name="pi-689-smoke-$(date +%s)-$$"
mkdir -p artifacts/trace-smoke
cleanup() { docker stop "$name" >/dev/null 2>&1 || true; docker rm "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" --network none -v "$PWD:/workspace:ro" \
    "${IRIS_IMAGE:-iris-community:2026.3.0AI.154.0}" >/dev/null
ready=0
for attempt in {1..40}; do
    if docker exec -i "$name" iris session IRIS -U USER <<< 'write "TRACE_READY",!' 2>/dev/null | grep -q TRACE_READY; then ready=1; break; fi
    sleep 1
done
[[ "$ready" == 1 ]] || { echo TRACE_INSTANCE_NOT_READY >&2; exit 1; }
docker exec -d -e TRACE_FIXTURE_PORT=18891 "$name" python3 /workspace/tests/trace_fixture.py
output=$(docker exec -i "$name" iris session IRIS -U USER <<'IRIS'
try { set sc=##class(%EnsembleMgr).EnableNamespace("USER") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } set sc=$system.OBJ.LoadDir("/workspace/src/PI/Trace","ck",,1) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } for file="InstallPaths","ToolAudit" { set sc=$system.OBJ.Load("/workspace/src/PI/"_file_".cls","ck") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } } for file="TraceTests","TraceFixtureTools","TraceFixtureWorker","TraceFixtureProduction" { set sc=$system.OBJ.Load("/workspace/tests/PI/"_file_".cls","ck") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } } do ##class(PI.TraceTests).Schema() set sc=##class(Ens.Director).StartProduction("PI.TraceFixtureProduction") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } write "TRACE_PRODUCTION_READY",! } catch ex { write "TRACE_SETUP_FAILED ",ex.DisplayString(),! }
halt
IRIS
)
printf '%s\n' "$output"
[[ "$output" == *TRACE_PRODUCTION_READY* && "$output" != *TRACE_SETUP_FAILED* && "$output" != *"Detected "*" errors"* ]] || exit 1
PI_TRACE_CONTAINER="$name" python3 -m unittest discover -s tests -p test_traceability_native.py -v
