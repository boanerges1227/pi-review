"""Verify real anonymous public-view accounting in an isolated PITEST application."""
from concurrent.futures import ThreadPoolExecutor
from http.cookiejar import CookieJar
import json
import os
import re
import secrets
import unittest
from urllib.error import HTTPError
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener

from mcp_token_acceptance import iris, literal


class VisitStatsAcceptance(unittest.TestCase):
    """Preserve the original test aggregate and remove the temporary application even after setup failure."""

    @classmethod
    def setUpClass(cls):
        cls.app = "/identity-visits-test-" + secrets.token_hex(6)
        cls.role = "PIVisitFixture" + secrets.token_hex(6)
        iris('set sc=$system.OBJ.Load("/workspace/tests/PI/VisitStatsHTTP.cls","ck") if $system.Status.IsOK(sc) { write "TOKEN_FIXTURE_OK",! }', namespace="PITEST")
        state = iris('write "VISIT_FIXTURE_STATE=",{"exists":($data(^PIVisitStats($namespace,"total"))#2),"total":(+$get(^PIVisitStats($namespace,"total")))}.%ToJSON(),! write "TOKEN_FIXTURE_OK",!', namespace="PITEST")
        cls.before = json.loads(re.search(r"VISIT_FIXTURE_STATE=(\{[^\n]+\})", state).group(1))
        cls.addClassCleanup(cls.cleanup)
        iris(f'''try {{
set sc=##class(Security.Roles).Create({literal(cls.role)},"Temporary process-environment fixture","%Service_EmbeddedPython:U","")
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("ROLE_FAILED") }}
set p("NameSpace")="PITEST",p("DispatchClass")="PI.VisitStatsHTTP",p("AutheEnabled")=96,p("Enabled")=1,p("Resource")="",p("MatchRoles")={literal(':%DB_USER:PIReviewRuntime:' + cls.role)},p("UseCookies")=2,p("CookiePath")={literal(cls.app + '/')},p("Timeout")=1800
set sc=##class(Security.Applications).Create({literal(cls.app)},.p)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("APP_FAILED") }}
write "TOKEN_FIXTURE_OK",!
}} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}''')

    @classmethod
    def cleanup(cls):
        """Restore only this counter's prior test value and remove the class-owned application."""
        restore = f'set ^PIVisitStats($namespace,"total")={cls.before["total"]}' if cls.before["exists"] else 'kill ^PIVisitStats($namespace,"total")'
        try:
            iris(restore + ' write "TOKEN_FIXTURE_OK",!', namespace="PITEST")
        finally:
            iris(f'try {{ set sc=##class(Security.Applications).Delete({literal(cls.app)}) set sc=##class(Security.Roles).Delete({literal(cls.role)}) if ##class(Security.Applications).Exists({literal(cls.app)})||##class(Security.Roles).Exists({literal(cls.role)}) {{ throw ##class(%Exception.General).%New("CLEANUP_FAILED") }} write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}')

    @staticmethod
    def opener():
        """Give each simulated browser a bounded native session without storing visitor identity."""
        return build_opener(ProxyHandler({}), HTTPCookieProcessor(CookieJar()))

    def setUp(self):
        self.client = self.opener()

    def tearDown(self):
        self.request("/logout", {}, client=self.client)

    def request(self, path, data=None, public=False, extra=None, method=None, client=None):
        """Exercise actual HTTP handling with proxy headers controlled only by this test client."""
        headers = {"Content-Type": "application/json", "X-Identity-Review": "local-demo"}
        if public:
            headers.update({"Host": "review.example.org", "X-Forwarded-Proto": "https", "CF-Ray": "fixture-ray-SJC"})
        headers.update(extra or {})
        request = Request(os.environ.get("PI_BASE", "http://127.0.0.1:52784") + self.app + path, None if data is None else json.dumps(data).encode(), headers, method=method)
        try:
            response = (client or self.client).open(request, timeout=30)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            try:
                body = json.loads(raw)
            except ValueError:
                body = raw.decode(errors="replace")
            return response.status, body, response.headers

    def total(self):
        """Read the aggregate without changing it or requiring administrator login."""
        status, body, headers = self.request("/visit-stats")
        self.assertEqual(status, 200)
        self.assertEqual(body["metric"], "public-login-page-views")
        self.assertIsInstance(body["total"], int)
        self.assertGreaterEqual(body["total"], 0)
        self.assertEqual(headers["Cache-Control"], "no-store")
        return body["total"]

    def test_public_gets_and_refreshes_increment_but_reads_do_not(self):
        before = self.total()
        self.assertEqual(self.total(), before)
        for offset in (1, 2):
            self.assertEqual(self.request("/login", public=True)[0], 200)
            self.assertEqual(self.total(), before + offset)
        self.assertEqual(self.request("/visit-stats?total=999999&reset=1")[1]["total"], before + 2)

    def test_local_wrong_origin_and_non_page_requests_do_not_increment(self):
        before = self.total()
        for extra in ({"CF-Ray": ""}, {"Host": "localhost:52784"}, {"Host": "review.example.org.evil.invalid"}, {"X-Forwarded-Proto": "http"}):
            self.assertEqual(self.request("/login", public=True, extra=extra)[0], 200)
        self.assertEqual(self.request("/login")[0], 200)
        for path in ("/login.js", "/login.css", "/visit-stats", "/session"):
            self.assertEqual(self.request(path, public=True)[0], 200)
        self.request("/login", public=True, method="HEAD")
        self.request("/login", {"username": "invalid-fixture", "password": "invalid-fixture"}, public=True)
        self.assertEqual(self.total(), before)

    def test_concurrent_public_page_views_are_not_lost(self):
        before = self.total()

        def browser(_):
            """Each browser refreshes four times and releases its own anonymous session."""
            client = self.opener()
            try:
                return [self.request("/login", public=True, client=client)[0] for _ in range(4)]
            finally:
                self.request("/logout", {}, client=client)

        with ThreadPoolExecutor(max_workers=3) as pool:
            statuses = list(pool.map(browser, range(3)))
        self.assertEqual(statuses, [[200] * 4] * 3)
        self.assertEqual(self.total(), before + 12)

    def test_disabled_origin_and_loopback_configuration_never_count(self):
        before = self.total()
        iris('do ##class(PI.VisitStats).Record("GET","review.example.org","https","fixture","") do ##class(PI.VisitStats).Record("GET","localhost:52784","http","fixture","http://localhost:52784") do ##class(PI.VisitStats).Record("GET","127.0.0.1:52784","http","fixture","http://127.0.0.1:52784") do ##class(PI.VisitStats).Record("GET","[::1]:52784","http","fixture","http://[::1]:52784") write "TOKEN_FIXTURE_OK",!', namespace="PITEST")
        self.assertEqual(self.total(), before)


if __name__ == "__main__":
    unittest.main()
