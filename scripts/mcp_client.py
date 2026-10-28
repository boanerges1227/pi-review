#!/usr/bin/env python3
"""Use the actual native MCP bridge without a model or command-line credentials."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.error import HTTPError
from urllib.request import Request, urlopen


class Client:
    """Support JSON and SSE responses from a Streamable HTTP MCP endpoint."""

    def __init__(self, config, token=None):
        self.url = config["url"]
        self.token = config["token"] if token is None else token
        self.session = None
        self.sequence = 0

    def rpc(self, method, params=None, notification=False):
        """Keep transport authentication local and return only decoded protocol results."""
        self.sequence += 1
        body = dict(jsonrpc="2.0", method=method, params=params or {})
        if not notification:
            body["id"] = self.sequence
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = Request(self.url, json.dumps(body).encode(), headers)
        try:
            with urlopen(req, timeout=20) as response:
                self.session = response.headers.get("Mcp-Session-Id", self.session)
                raw = response.read(100000)
                if not raw:
                    return {}
                text = raw.decode()
                if response.headers.get("Content-Type", "").startswith("text/event-stream"):
                    rows = [json.loads(line[5:].strip()) for line in text.splitlines() if line.startswith("data:") and line[5:].strip()]
                    return next(row for row in rows if row.get("id") == self.sequence)
                return json.loads(text)
        except HTTPError as exc:
            return {"httpStatus": exc.code}

    def initialize(self):
        """Negotiate protocol and acknowledge initialization before tool operations."""
        result = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "identity-review-local", "version": "1.0"}})
        if "result" in result:
            self.rpc("notifications/initialized", notification=True)
        return result


def grant(case_id, namespace):
    """Grant a known case via trusted local IRIS administration, never via the MCP API."""
    if not re.fullmatch(r"c[1-9][0-9]*", case_id) or namespace not in ("USER", "PITEST"):
        raise SystemExit("Invalid case or namespace")
    program = f'try {{ do ##class(PI.MCP.Access).Grant("{case_id}") write "MCP_GRANT_OK",! }} catch ex {{ write "MCP_GRANT_FAILED",! }}\nhalt\n'
    result = subprocess.run(["docker", "compose", "exec", "-T", "iris", "iris", "session", "IRIS", "-U", namespace], input=program, text=True, capture_output=True, timeout=20)
    if "MCP_GRANT_OK" not in result.stdout or "MCP_GRANT_FAILED" in result.stdout:
        raise SystemExit("Case grant failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="artifacts/mcp-client.json")
    parser.add_argument("--grant")
    parser.add_argument("--namespace", default="USER")
    parser.add_argument("--case")
    parser.add_argument("--version", type=int)
    args = parser.parse_args()
    if args.grant:
        grant(args.grant, args.namespace)
        print("Explicit case grant saved")
    else:
        client = Client(json.loads(Path(args.config).read_text()))
        result = client.initialize()
        if "result" not in result:
            raise SystemExit("MCP initialization failed")
        tools = client.rpc("tools/list").get("result", {}).get("tools", [])
        if args.case and args.version:
            tool = next((t["name"] for t in tools if t["name"].endswith("review_case")), None)
            if not tool:
                raise SystemExit("Readonly case tool was not advertised")
            result = client.rpc("tools/call", {"name": tool, "arguments": {"caseId": args.case, "expectedVersion": args.version}})
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(json.dumps({"tools": [t["name"] for t in tools]}, indent=2))
