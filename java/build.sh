#!/usr/bin/env bash
set -euo pipefail
# Compile with the matching IRIS SDK; retain dependencies outside readonly source mounts.
source_dir=$(cd "$(dirname "$0")" && pwd)
target=${1:?JAVA_BUILD_DIRECTORY_REQUIRED}
iris_lib=${PI_IRIS_JAVA_LIB:-/usr/irissys/dev/java/lib/1.8}
mkdir -p "$target/lib"
dependency="$target/lib/icu4j-72.1.jar"
digest=3df572b240a68d13b5cd778ad2393e885d26411434cd8f098ac5987ea2e64ce3
valid_dependency() { [[ -f "$dependency" ]] && [[ $(sha256sum "$dependency" | cut -d ' ' -f1) == "$digest" ]]; }
if ! valid_dependency; then
    # Pin Unicode15, matching the supported image's Python normalization and full casefold tables.
    temp=$(mktemp "$target/lib/icu4j.XXXXXX")
    trap 'rm -f "$temp"' EXIT
    python3 - "$temp" <<'PY'
import shutil
import sys
import urllib.request

with urllib.request.urlopen("https://repo.maven.apache.org/maven2/com/ibm/icu/icu4j/72.1/icu4j-72.1.jar", timeout=60) as source:
    with open(sys.argv[1], "wb") as target:
        shutil.copyfileobj(source, target)
PY
    [[ $(sha256sum "$temp" | cut -d ' ' -f1) == "$digest" ]] || { echo ICU_CHECKSUM_FAILED >&2; exit 1; }
    mv "$temp" "$dependency"
fi
classes=$(mktemp -d "$target/classes.XXXXXX")
trap 'rm -rf "$classes"; [[ -z ${temp:-} ]] || rm -f "$temp"' EXIT
javac --release 11 -encoding UTF-8 -cp "$iris_lib/*:$dependency" -d "$classes" \
    "$source_dir"/src/org/pireview/pex/*.java
jar --create --file "$classes/pi-name-pex.jar" -C "$classes" org
mv "$classes/pi-name-pex.jar" "$target/pi-name-pex.jar"
echo PI_JAVA_PEX_BUILD_OK
