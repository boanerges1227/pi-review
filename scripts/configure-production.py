#!/usr/bin/env python3
"""Configure native Production URL login without putting the demo password in source or command arguments."""
import argparse
import getpass
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    """Write a private, atomic credential file inside this Compose project's IRIS container."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--username", required=True)
    parser.add_argument("--namespace", default="USER")
    parser.add_argument("--password-stdin", action="store_true", help="Read the password from stdin instead of an interactive prompt")
    args = parser.parse_args()
    namespace = args.namespace.upper()
    if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", namespace):
        parser.error("Invalid namespace")
    password = sys.stdin.readline().rstrip("\r\n") if args.password_stdin else getpass.getpass("Production demo password: ")
    if not (1 <= len(args.username) <= 128 and 1 <= len(password) <= 2048):
        parser.error("Username or password length is invalid")
    # Credentials travel through stdin only; the container writes an owner-only file using atomic replacement.
    program = '''import json,os,sys,tempfile
data=json.load(sys.stdin)
namespace=data.pop("namespace")
path=os.environ.get("PI_PRODUCTION_CREDENTIALS_FILE") or "/durable/iris/private/production-login-"+namespace+".json"
directory=os.path.dirname(path)
os.umask(0o077)
os.makedirs(directory,mode=0o700,exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix=".production-login-",dir=directory)
try:
    with os.fdopen(fd,"w",encoding="utf-8") as stream:
        json.dump(data,stream,ensure_ascii=False)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
'''
    payload = json.dumps({"username": args.username, "password": password, "namespace": namespace}, ensure_ascii=False)
    result = subprocess.run(["docker", "compose", "exec", "-T", "iris", "python3", "-c", program], input=payload, text=True, capture_output=True, cwd=Path(__file__).resolve().parents[1], timeout=30)
    if result.returncode:
        raise SystemExit("Production configuration failed; private diagnostics suppressed.")
    print(f"Production demo login configured for {namespace}; reload /identity/production.")


if __name__ == "__main__":
    main()
