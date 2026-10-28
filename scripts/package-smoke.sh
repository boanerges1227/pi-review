#!/usr/bin/env bash
set -euo pipefail
# Install into a disposable IRIS container without source bind mounts or access to the active project's volumes.
cd "$(dirname "$0")/.."
installer=${PI_IPM_INSTALLER:-artifacts/contest-verification/zpm-0.10.9.xml}
[[ -f "$installer" ]] || { printf 'IPM_INSTALLER_REQUIRED\n' >&2; exit 1; }
mkdir -p artifacts/contest-verification
smoke_name="pi-review-package-smoke-$(date +%s)-$$"
smoke_volume="${smoke_name}-data"
stage=$(mktemp -d)
cleanup() {
  docker rm -f "$smoke_name" >/dev/null 2>&1 || true
  docker volume rm "$smoke_volume" >/dev/null 2>&1 || true
  rm -rf "$stage"
}
trap cleanup EXIT
cp module.xml LICENSE "$stage/"
cp -R src web data "$stage/"
chmod -R a+rX "$stage"
# Match deployed containers: Durable %SYS makes the installation tree read-only.
image=${IRIS_IMAGE:-iris-community:2026.3.0AI.154.0}
docker volume create "$smoke_volume" >/dev/null
docker run --rm --user 0 --entrypoint /bin/sh -v "$smoke_volume:/durable" "$image" \
  -c 'chown irisowner:irisowner /durable'
docker run -d --name "$smoke_name" -e ISC_DATA_DIRECTORY=/durable/iris \
  -v "$smoke_volume:/durable" "$image" >/dev/null
ready=0
for attempt in {1..40}; do
  if docker exec -i "$smoke_name" iris session IRIS -U USER <<< 'write "SMOKE_READY",!' 2>/dev/null | grep -q SMOKE_READY; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]] || { printf 'PACKAGE_SMOKE_NOT_READY\n' >&2; exit 1; }
docker cp "$installer" "$smoke_name:/tmp/pi-ipm-installer.xml" >/dev/null
docker cp "$stage/." "$smoke_name:/tmp/pi-review-package" >/dev/null
output=$(docker exec -i "$smoke_name" iris session IRIS -U USER <<'IRIS'
set sc=$system.OBJ.Load("/tmp/pi-ipm-installer.xml","ck")
if $system.Status.IsError(sc) { write "PACKAGE_SMOKE_FAILED_INSTALLER",! halt }
set sc=##class(%EnsembleMgr).EnableNamespace("USER")
if $system.Status.IsError(sc) { write "PACKAGE_SMOKE_FAILED_INTEROP",! halt }
zpm "load /tmp/pi-review-package -v"
if ##class(%Dictionary.CompiledClass).%ExistsId("PI.InstallPaths")=0 { write "PACKAGE_SMOKE_FAILED_INSTALL",! halt }
write "INSTALLED_ROOT=",##class(PI.InstallPaths).Root(),!
if ##class(PI.InstallPaths).Root()="/workspace/" { write "PACKAGE_SMOKE_FAILED_PATH",! halt }
if ##class(PI.InstallPaths).Root()'=($system.Util.ManagerDirectory()_"pi-review/") { write "PACKAGE_SMOKE_FAILED_DURABLE_PATH",! halt }
if ##class(%File).Exists(##class(PI.InstallPaths).WebRoot()_"index.html")=0 { write "PACKAGE_SMOKE_FAILED_WEB",! halt }
if ##class(%File).Exists(##class(PI.InstallPaths).SourceRegistryPath())=0 { write "PACKAGE_SMOKE_FAILED_SOURCE",! halt }
set stored=##class(PI.Store).Ingest({"sourceSystem":"HIS","sourcePatientId":"PACKAGE-SMOKE","sourceVersion":1,"name":"Package Smoke Synthetic","birthDate":"1980-01-01","sex":"F","identifier":"SYN-PACKAGE-SMOKE","phone":"","notes":"synthetic"})
set ^PIData($namespace,"packageSmokeRecord")=stored.recordId
zpm "load /tmp/pi-review-package -v"
if (##class(PI.Store).Record(^PIData($namespace,"packageSmokeRecord")).sourcePatientId="PACKAGE-SMOKE")=0 { write "PACKAGE_SMOKE_FAILED_REINSTALL",! halt }
write "PACKAGE_SMOKE_INSTALLED",!
halt
IRIS
)
printf '%s\n' "$output"
[[ "$output" == *PACKAGE_SMOKE_INSTALLED* && "$output" != *PACKAGE_SMOKE_FAILED* && "$output" != *FAILURE* && "$output" != *"Detected "*" errors"* ]] || exit 1
# The runtime check occurs after the temporary source package has been removed.
docker exec --user 0 "$smoke_name" rm -rf /tmp/pi-review-package
output=$(docker exec -i "$smoke_name" iris session IRIS -U USER <<'IRIS'
try { set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile(##class(PI.InstallPaths).SourceRegistryPath()) if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } set fixture={}.%FromJSON(stream) if fixture.%IsDefined("HIS:DEMO-HIS-001")=0 { throw ##class(%Exception.General).%New("FIXTURE_MISSING") } set page=##class(%Stream.FileCharacter).%New(),sc=page.LinkToFile(##class(PI.InstallPaths).WebRoot()_"index.html") if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) } if page.Read(1024)'["<!doctype html>" { throw ##class(%Exception.General).%New("WEB_MISSING") } write "PACKAGE_SMOKE_OK",! } catch ex { write "PACKAGE_SMOKE_FAILED_RUNTIME ",ex.Name,! }
halt
IRIS
)
printf '%s\n' "$output"
[[ "$output" == *PACKAGE_SMOKE_OK* && "$output" != *PACKAGE_SMOKE_FAILED* ]]
