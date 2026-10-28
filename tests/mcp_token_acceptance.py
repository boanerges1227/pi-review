"""Validate tokens through an isolated administrator HTTP application and native MCP gateway without model calls."""
from http.cookiejar import CookieJar
import os
import importlib.util
import json
from pathlib import Path
import re
import secrets
import subprocess
import unittest
from urllib.error import HTTPError
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mcp_client", ROOT / "scripts/mcp_client.py")
client_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client_module)


def iris(program, namespace="%SYS"):
    """Pass temporary credentials through standard input and never log raw output containing secrets."""
    # The IRIS interactive terminal requires a complete block on one input line; source line breaks improve readability.
    program = " ".join(line.strip() for line in program.splitlines())
    result = subprocess.run(["docker", "compose", "exec", "-T", "iris", "iris", "session", "IRIS", "-U", namespace], input=program + "\nhalt\n", capture_output=True, text=True, timeout=30, cwd=ROOT)
    if result.returncode or "TOKEN_FIXTURE_OK" not in result.stdout or "TOKEN_FIXTURE_FAILED" in result.stdout:
        raise RuntimeError("Token acceptance fixture failed; credential-bearing diagnostics suppressed")
    return result.stdout


def literal(value):
    """Escape ObjectScript string literals without passing passwords through shell interpolation or command arguments."""
    return '"' + value.replace('"', '""') + '"'


class TokenAcceptance(unittest.TestCase):
    """Manage temporary tokens only in PITEST and remove the temporary application, user, and role afterward."""

    def test_admin_http_and_native_gateway_lifecycle(self):
        """Verify authentication boundaries, creation, ACL changes, persistent connection revocation, expiry, and version conflicts."""
        suffix = secrets.token_hex(6)
        user = "PITokenTest" + suffix
        role = user + "Role"
        app = "/identity-token-test-" + suffix
        password = "T9!" + secrets.token_hex(24)
        opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(CookieJar()))
        created_ids = []

        def request(path="", data=None, extra=None, route=None):
            """IRIS verifies administrator authentication; the test supplies only a random temporary account."""
            headers = {"Content-Type": "application/json", "X-Identity-Review": "local-demo"}
            if extra:
                headers.update(extra)
            req = Request(os.environ.get("PI_BASE", "http://127.0.0.1:52784") + app + (route or "/mcp-tokens" + path), None if data is None else json.dumps(data).encode(), headers)
            try:
                response = opener.open(req, timeout=20)
            except HTTPError as error:
                response = error
            with response:
                return response.status, json.load(response), response.headers

        setup = f'''try {{
set sc=##class(Security.Roles).Create({literal(role)},"Temporary isolated token acceptance","%Admin_ConfigStore:U,%Admin_Wallet:U,%DB_USER:RW","")
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("ROLE_FAILED") }}
set u("Roles")={literal(role)},u("Password")={literal(password)},u("Enabled")=1,u("ChangePassword")=0
set sc=##class(Security.Users).Create({literal(user)},.u)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("USER_FAILED") }}
set p("NameSpace")="PITEST",p("DispatchClass")="PI.ConfigREST",p("AutheEnabled")=96,p("Enabled")=1,p("Resource")="",p("MatchRoles")=":%DB_USER"
set sc=##class(Security.Applications).Create({literal(app)},.p)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("APP_FAILED") }}
write "TOKEN_FIXTURE_OK",!
}} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}'''
        try:
            iris(setup)
            request(data={}, route="/logout")
            status, session, _ = request(data={"username":user,"password":password}, route="/login")
            self.assertEqual(status, 200)
            self.assertTrue(session["authenticated"])
            status, listing, headers = request()
            self.assertEqual(status, 200)
            self.assertEqual(listing["namespace"], "PITEST")
            self.assertEqual(headers.get("Cache-Control"), "no-store")
            self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
            data = {"label": "Native gateway acceptance", "expiresInDays": 1, "cases": ["c1"]}
            for extra in ({"Origin": "https://example.com"}, {"X-Identity-Review": ""}):
                status, _, _ = request(data=data, extra=extra)
                self.assertEqual(status, 403)
            status, created, headers = request(data=data)
            self.assertEqual(status, 200)
            token, item = created["token"], created["item"]
            created_ids.append(item["id"])
            self.assertTrue(re.fullmatch(r"pi_mcp_[A-Za-z0-9_-]{43}", token) is not None, "32-byte token uses a safe URL alphabet")
            status, listing, _ = request()
            self.assertTrue(token not in json.dumps(listing), "list must never return the token")
            self.assertTrue("hash" not in json.dumps(listing), "list must never return a digest")
            client = client_module.Client({"url": os.environ.get("PI_TEST_MCP_URL", "http://127.0.0.1:52786/mcp"), "token": token})
            self.assertTrue("result" in client.initialize(), "new token initializes the native gateway")
            tools = client.rpc("tools/list").get("result", {}).get("tools", [])
            name = next(tool["name"] for tool in tools if tool["name"].endswith("review_case"))
            version_output = iris('write "TOKEN_CASE_VERSION=",##class(PI.Store).Case("c1").version,! write "TOKEN_FIXTURE_OK",!', "PITEST")
            version = int(re.search(r"TOKEN_CASE_VERSION=(\d+)", version_output)[1])

            def allowed():
                """Check actual tool results on the same client connection; discovery does not grant case access."""
                result = client.rpc("tools/call", {"name": name, "arguments": {"caseId": "c1", "expectedVersion": version}})
                return "result" in result and not result["result"].get("isError", True)

            self.assertTrue(allowed(), "new token reads its granted case")
            status, updated, _ = request("/" + item["id"], {"label": "No case access", "version": 1, "cases": []})
            self.assertEqual(status, 200)
            self.assertFalse(allowed(), "existing native connection loses removed case ACL")
            status, _, _ = request("/" + item["id"], {"label": "Stale", "version": 1, "cases": ["c1"]})
            self.assertEqual(status, 409)
            status, updated, _ = request("/" + item["id"], {"label": "Restored", "version": 2, "cases": ["c1"]})
            self.assertEqual(status, 200)
            self.assertTrue(allowed(), "explicit current-version edit restores only the chosen case")
            status, revoked, _ = request("/" + item["id"] + "/revoke", {"version": 3})
            self.assertEqual(status, 200)
            self.assertEqual(revoked["status"], "REVOKED")
            self.assertFalse(allowed(), "revocation rejects an existing native connection")
            status, expiring, _ = request(data=data)
            self.assertEqual(status, 200)
            created_ids.append(expiring["item"]["id"])
            client = client_module.Client({"url": os.environ.get("PI_TEST_MCP_URL", "http://127.0.0.1:52786/mcp"), "token": expiring["token"]})
            self.assertTrue("result" in client.initialize())
            self.assertTrue(allowed())
            token_id = literal(expiring["item"]["id"])
            iris(f'try {{ set m={{}}.%FromJSON(^PIMCPAccess($namespace,"managed",{token_id})),m.expiresAtEpoch=1,^PIMCPAccess($namespace,"managed",{token_id})=m.%ToJSON() write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}', "PITEST")
            self.assertFalse(allowed(), "expiry is rechecked on the existing native connection")
            status, listing, _ = request()
            expired = next(row for row in listing["tokens"] if row["id"] == expiring["item"]["id"])
            self.assertEqual(expired["status"], "EXPIRED")
        finally:
            try:
                for token_id in created_ids:
                    iris(f'try {{ set m={{}}.%FromJSON(^PIMCPAccess($namespace,"managed",{literal(token_id)})) if m.revokedAtEpoch=0 {{ set r=##class(PI.MCP.Tokens).Revoke({literal(token_id)},{{"version":(m.version)}}) }} write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}', "PITEST")
            finally:
                request(data={}, route="/logout")
                # Attempt to delete the temporary administrator and verify removal even if token cleanup fails.
                iris(f'try {{ set sc=##class(Security.Applications).Delete({literal(app)}) set sc=##class(Security.Users).Delete({literal(user)}) set sc=##class(Security.Roles).Delete({literal(role)}) if ##class(Security.Applications).Exists({literal(app)})||##class(Security.Users).Exists({literal(user)})||##class(Security.Roles).Exists({literal(role)}) {{ throw ##class(%Exception.General).%New("CLEANUP_FAILED") }} write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}')


if __name__ == "__main__":
    unittest.main(verbosity=2)
