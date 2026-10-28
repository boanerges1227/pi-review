"""Verify the native IRIS MCP bridge over HTTP without any paid model call."""
import os
import importlib.util
import json
from pathlib import Path
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("mcp_client", ROOT/"scripts/mcp_client.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeAcceptance(unittest.TestCase):
    """Use real native gateway discovery, authorization, and case-version checks."""

    @classmethod
    def setUpClass(cls):
        cls.config = json.loads((ROOT/"artifacts/mcp-test-client.json").read_text())
        module.grant("c1", "PITEST")
        cls.client = module.Client(cls.config)
        assert "result" in cls.client.initialize()
        cls.tools = cls.client.rpc("tools/list").get("result", {}).get("tools", [])

    def call(self, suffix, case="c1", version=1):
        name = next(t["name"] for t in self.tools if t["name"].endswith(suffix))
        return self.client.rpc("tools/call", {"name": name, "arguments": {"caseId": case, "expectedVersion": version}})

    def test_only_three_readonly_tools_are_advertised(self):
        self.assertEqual({t["name"] for t in self.tools}, {"mcp_identity-test_review_case", "mcp_identity-test_review_evidence", "mcp_identity-test_review_run_trace"})

    def test_allowed_case_and_evidence_can_be_read(self):
        # The fixture's exact version is saved by the test runner, not derived by the method under test.
        version = int((ROOT/"artifacts/mcp-test-version.txt").read_text())
        result = self.call("review_case", version=version)
        self.assertFalse(result.get("result", {}).get("isError", True), result)
        text = result["result"]["content"][0]["text"]
        self.assertIn('"id":"c1"', text.replace(" ", ""))
        evidence = self.call("review_evidence", version=version)
        self.assertFalse(evidence.get("result", {}).get("isError", True))
        trace = self.call("review_run_trace", version=version)
        self.assertFalse(trace.get("result", {}).get("isError", True))

    def test_foreign_case_and_stale_version_are_denied(self):
        for result in (self.call("review_case", case="c99999"), self.call("review_case", version=999999)):
            self.assertTrue(result.get("result", {}).get("isError") or result.get("error"), result)

    def test_invalid_client_does_not_reuse_authenticated_catalog_or_connection(self):
        other = module.Client(self.config, token="invalid-token")
        other.initialize()
        tools = other.rpc("tools/list").get("result", {}).get("tools", [])
        self.assertEqual(tools, [])
        name = self.tools[0]["name"]
        result = other.rpc("tools/call", {"name": name, "arguments": {"caseId": "c1", "expectedVersion": 1}})
        self.assertTrue(result.get("httpStatus") or result.get("error") or result.get("result", {}).get("isError"), result)

    def test_native_type18_backend_is_not_a_regular_web_application(self):
        for value in (None, "Bearer invalid-token"):
            headers = {} if value is None else {"Authorization": value}
            request = Request(os.environ.get("PI_BASE", "http://127.0.0.1:52784") + "/mcp/identity-test/v1/services", headers=headers)
            with self.assertRaises(HTTPError) as failure:
                urlopen(request, timeout=10)
            self.assertEqual(failure.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
