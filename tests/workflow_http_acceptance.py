"""Verify real session, native task ownership and guarded decisions through the public HTTP routes."""
import re
import secrets
import unittest
from http.cookiejar import CookieJar
from urllib.request import HTTPCookieProcessor, ProxyHandler, build_opener

import admin_login_acceptance as admin_fixture
from mcp_token_acceptance import iris, literal


class WorkflowHTTPAcceptance(unittest.TestCase):
    """Use temporary identities and synthetic PITEST records; never read persistent administrator credentials."""

    request = admin_fixture.AdminLoginAcceptance.request
    setUp = admin_fixture.AdminLoginAcceptance.setUp
    tearDown = admin_fixture.AdminLoginAcceptance.tearDown

    @classmethod
    def cleanup(cls):
        """Remove workflow memberships before deleting the temporary security identities."""
        if hasattr(cls, "user"):
            iris(f'''set sc=##class(EnsLib.Workflow.RoleDefinition).RemoveUserFromRole("IdentityReview",{literal(cls.user)})
set sc=##class(EnsLib.Workflow.UserDefinition).DeleteUser({literal(cls.user)})
write "TOKEN_FIXTURE_OK",!''', "PITEST")
        admin_fixture.AdminLoginAcceptance.cleanup.__func__(cls)

    @classmethod
    def setUpClass(cls):
        admin_fixture.AdminLoginAcceptance.setUpClass.__func__(cls)
        iris(f'''set p("DispatchClass")="PI.REST"
set sc=##class(Security.Applications).Modify({literal(cls.app)},.p)
set u("Roles")={literal(cls.role)}
set sc=##class(Security.Users).Modify({literal(cls.reader)},.u)
write "TOKEN_FIXTURE_OK",!''')
        iris(f'''do ##class(PI.Workflow.Setup).Install({literal(cls.user)})
write "TOKEN_FIXTURE_OK",!''', "PITEST")

    @classmethod
    def tearDownClass(cls):
        cls.cleanup()

    def test_claim_is_required_and_nonmember_cannot_approve(self):
        """An authenticated administrator still needs native task membership and ownership for approval."""
        suffix = secrets.token_hex(8)
        output = iris(f'''set a=##class(PI.Tests).Input("HIS",{literal('workflow-http-' + suffix)})
set a.identifier={literal('SYN-WF-' + suffix)},a.name={literal('Workflow Synthetic ' + suffix)}
set first=##class(PI.Store).Ingest(a)
set a.sourceSystem="EMR",second=##class(PI.Store).Ingest(a)
write "WORKFLOW_CASE=",second.caseId," CANDIDATE=r",first.recordId,!
write "TOKEN_FIXTURE_OK",!''', "PITEST")
        case_id, candidate = re.search(r"WORKFLOW_CASE=(c\d+) CANDIDATE=(r\d+)", output).groups()
        status, _, _ = self.request("/login", {"username": self.user, "password": self.password})
        self.assertEqual(status, 200)
        decision = {"version": 1, "action": "LINK", "candidateId": candidate, "reason": "Synthetic HTTP workflow approval"}
        status, body, _ = self.request(f"/cases/{case_id}/review", decision)
        self.assertEqual((status, body.get("code")), (409, "WORKFLOW_CLAIM_REQUIRED"))
        status, task, _ = self.request(f"/cases/{case_id}/claim", {"version": 1, "actor": self.reader})
        self.assertEqual(status, 200, task)
        self.assertEqual(task["assignedTo"], self.user)
        other = build_opener(ProxyHandler({}), HTTPCookieProcessor(CookieJar()))
        try:
            status, _, _ = self.request("/login", {"username": self.reader, "password": self.password}, opener=other)
            self.assertEqual(status, 200)
            status, body, _ = self.request(f"/cases/{case_id}/review", decision, opener=other)
            self.assertEqual((status, body.get("code")), (403, "WORKFLOW_FORBIDDEN"))
        finally:
            self.request("/logout", {}, opener=other)
        status, body, _ = self.request(f"/cases/{case_id}/review", decision)
        self.assertEqual(status, 200, body)
        self.assertEqual(body["status"], "APPROVED")
        approved_version = body["version"]
        try:
            self.request("/login", {"username": self.reader, "password": self.password}, opener=other)
            status, body, _ = self.request(f"/cases/{case_id}/undo", {"version": approved_version, "reason": "Nonmember undo attempt"}, opener=other)
            self.assertEqual((status, body.get("code")), (403, "WORKFLOW_FORBIDDEN"))
        finally:
            self.request("/logout", {}, opener=other)
        iris(f'''set sc=##class(EnsLib.Workflow.RoleDefinition).RemoveUserFromRole("IdentityReview",{literal(self.user)})
write "TOKEN_FIXTURE_OK",!''', "PITEST")
        status, body, _ = self.request(f"/cases/{case_id}/undo", {"version": approved_version, "reason": "Revoked reviewer undo attempt"})
        self.assertEqual((status, body.get("code")), (403, "WORKFLOW_FORBIDDEN"))
        iris(f'''do ##class(PI.Workflow.Setup).Install({literal(self.user)})
write "TOKEN_FIXTURE_OK",!''', "PITEST")
        status, _, _ = self.request(f"/cases/{case_id}/review", decision)
        self.assertEqual(status, 409)

    def test_health_budget_uses_dollars(self):
        """Both UI pages receive dollar amounts and an explicit currency instead of legacy yuan fields."""
        status, _, _ = self.request("/login", {"username": self.user, "password": self.password})
        self.assertEqual(status, 200)
        status, budget, _ = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(budget["currency"], "USD")
        self.assertEqual(budget["budgetUsd"], 3)
        self.assertTrue({"estimatedUsd", "knownEstimateUsd", "unknownUsageUsd", "reservedUsd"}.issubset(budget))
        self.assertFalse(any(key.endswith("Cny") for key in budget))

    def test_health_preserves_json_during_legacy_inflight(self):
        """An old in-flight reservation yields a controlled JSON retry response, without partial currency conversion."""
        status, _, _ = self.request("/login", {"username": self.user, "password": self.password})
        self.assertEqual(status, 200)
        iris('''merge ^PITestHealthBudgetBackup=^PIBudget($namespace)
kill ^PIBudget($namespace)
set ^PIBudget($namespace,"spentCny")=.5,^PIBudget($namespace,"reservedCny")=15,^PIBudget($namespace,"reservation",1)="OPEN"
write "TOKEN_FIXTURE_OK",!''', "PITEST")
        try:
            status, body, headers = self.request("/health")
            self.assertEqual((status, body.get("code")), (503, "BUDGET_MIGRATION_BUSY"))
            self.assertTrue(headers.get("Content-Type", "").startswith("application/json"))
        finally:
            iris('''kill ^PIBudget($namespace)
merge ^PIBudget($namespace)=^PITestHealthBudgetBackup
kill ^PITestHealthBudgetBackup
write "TOKEN_FIXTURE_OK",!''', "PITEST")


if __name__ == "__main__":
    unittest.main()
