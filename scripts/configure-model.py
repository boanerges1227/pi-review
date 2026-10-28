#!/usr/bin/env python3
"""Bootstrap native Wallet from local administrator configuration without printing keys or complete commands."""
import os
import subprocess
from pathlib import Path


def configure():
    # Read .env only in the host administrator process; pass secrets through standard input to avoid argument-list exposure.
    values = {}
    path = Path(__file__).resolve().parent.parent / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip("\"'")
    values.update({k: os.environ[k] for k in ("PI_API_KEY", "PI_MODEL", "PI_BASE_URL") if k in os.environ})
    args = [values.get(k, "") for k in ("PI_API_KEY", "PI_BASE_URL", "PI_MODEL")]
    if not all(args):
        print("MODEL_CONFIG_SKIPPED: local configuration incomplete")
        return
    quoted = [chr(34) + v.replace(chr(34), chr(34) * 2) + chr(34) for v in args]
    program = "try { do ##class(PI.ModelConfig).Install(" + ",".join(quoted) + ") write \"MODEL_CONFIG_OK\",! } catch ex { write \"MODEL_CONFIG_FAILED\",! }\nhalt\n"
    result = subprocess.run(["docker", "compose", "exec", "-T", "iris", "iris", "session", "IRIS", "-U", "USER"], input=program, text=True, capture_output=True)
    if result.returncode or "MODEL_CONFIG_OK" not in result.stdout:
        raise SystemExit("MODEL_CONFIG_FAILED: check named configuration and administrator resources")
    print("MODEL_CONFIG_OK: native Config Store and Wallet")


if __name__ == "__main__":
    configure()
