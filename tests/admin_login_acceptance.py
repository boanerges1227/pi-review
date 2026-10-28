"""Verify administrator login with temporary IRIS users and a PITEST application without reading user passwords."""
import os
import base64
import copy
from http.cookiejar import CookieJar
import json
import secrets
import time
import unittest
from urllib.error import HTTPError
from urllib.request import HTTPCookieProcessor, ProxyHandler, Request, build_opener

from mcp_token_acceptance import iris, literal


class AdminLoginAcceptance(unittest.TestCase):
    """Keep temporary users, applications, and cookies separate from administrator sessions and verify cleanup."""

    @classmethod
    def setUpClass(cls):
        suffix = secrets.token_hex(6)
        cls.user = "PIAdminLogin" + suffix
        cls.reader = cls.user + "Reader"
        cls.role = cls.user + "Role"
        cls.app = "/identity-login-test-" + suffix
        cls.password = "T9!" + secrets.token_hex(24)
        try:
            iris(f'''try {{
set sc=##class(Security.Roles).Create({literal(cls.role)},"Temporary admin login acceptance","%Admin_ConfigStore:U,%Admin_Wallet:U,%DB_USER:RW","")
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("ROLE_FAILED") }}
set u("Roles")={literal(cls.role)},u("Password")={literal(cls.password)},u("Enabled")=1,u("ChangePassword")=0
set sc=##class(Security.Users).Create({literal(cls.user)},.u)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("USER_FAILED") }}
kill u set u("Roles")="%DB_USER",u("Password")={literal(cls.password)},u("Enabled")=1,u("ChangePassword")=0
set sc=##class(Security.Users).Create({literal(cls.reader)},.u)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("READER_FAILED") }}
set p("NameSpace")="PITEST",p("DispatchClass")="PI.ConfigREST",p("AutheEnabled")=96,p("Enabled")=1,p("Resource")="",p("MatchRoles")=":%DB_USER",p("UseCookies")=2,p("CookiePath")={literal(cls.app + '/')},p("Timeout")=1800
set sc=##class(Security.Applications).Create({literal(cls.app)},.p)
if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("APP_FAILED") }}
write "TOKEN_FIXTURE_OK",!
}} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}''')
        except Exception:
            cls.cleanup()
            raise

    @classmethod
    def cleanup(cls):
        """Delete temporary security objects and verify removal without logging passwords or session cookies."""
        iris(f'''try {{
set sc=##class(Security.Applications).Delete({literal(cls.app)})
set sc=##class(Security.Users).Delete({literal(cls.user)})
set sc=##class(Security.Users).Delete({literal(cls.reader)})
set sc=##class(Security.Roles).Delete({literal(cls.role)})
if ##class(Security.Applications).Exists({literal(cls.app)})||##class(Security.Users).Exists({literal(cls.user)})||##class(Security.Users).Exists({literal(cls.reader)})||##class(Security.Roles).Exists({literal(cls.role)}) {{ throw ##class(%Exception.General).%New("CLEANUP_FAILED") }}
write "TOKEN_FIXTURE_OK",!
}} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}''')

    @classmethod
    def tearDownClass(cls):
        cls.cleanup()

    def setUp(self):
        self.jar = CookieJar()
        self.opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(self.jar))

    def tearDown(self):
        """End each native session to release limited development instance licenses."""
        self.request("/logout", {})

    def request(self, path, data=None, extra=None, opener=None):
        """Send credentials only in HTTP request bodies and never print sensitive request content on failure."""
        headers = {"Content-Type": "application/json", "X-Identity-Review": "local-demo"}
        headers.update(extra or {})
        request = Request(os.environ.get("PI_BASE", "http://127.0.0.1:52784") + self.app + path, None if data is None else json.dumps(data).encode(), headers)
        try:
            response = (opener or self.opener).open(request, timeout=20)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            try:
                body = json.loads(raw)
            except ValueError:
                body = {"code": "NON_JSON_RESPONSE"}
            return response.status, body, response.headers

    def login(self, username=None):
        """End the anonymous session before IRIS creates a new session and verifies the password."""
        status, _, _ = self.request("/logout", {})
        self.assertEqual(status, 200)
        return self.request("/login", {"username": username or self.user, "password": self.password})

    def test_existing_anonymous_session_cannot_be_promoted(self):
        self.request("/session")
        status, body, _ = self.request("/login", {"username": self.user, "password": self.password})
        self.assertEqual(status, 409)
        self.assertEqual(body["code"], "ADMIN_NEW_SESSION_REQUIRED")

    def test_session_is_anonymous_without_login_and_has_no_basic_challenge(self):
        status, body, headers = self.request("/session")
        self.assertEqual(status, 200)
        self.assertFalse(body["authenticated"])
        self.assertEqual(headers.get("Cache-Control"), "no-store")
        status, _, headers = self.request("/mcp-tokens")
        self.assertEqual(status, 401)
        self.assertIsNone(headers.get("WWW-Authenticate"))

    def test_native_login_cookie_rotation_management_and_logout(self):
        self.request("/session")
        before = {(cookie.name, cookie.value) for cookie in self.jar}
        anonymous = CookieJar()
        for cookie in self.jar:
            anonymous.set_cookie(copy.copy(cookie))
        status, body, _ = self.login()
        self.assertEqual(status, 200)
        self.assertTrue(body["authenticated"])
        self.assertEqual(body["username"].lower(), self.user.lower())
        after = {(cookie.name, cookie.value) for cookie in self.jar}
        self.assertTrue(before != after, "login must rotate the anonymous session cookie")
        session_cookies = [cookie for cookie in self.jar if cookie.name.startswith("CSPSESSIONID")]
        self.assertTrue(session_cookies)
        self.assertTrue(all(any(cookie.has_nonstandard_attr(name) for name in ("HttpOnly", "httpOnly", "httponly")) for cookie in session_cookies), "native session cookie must be HttpOnly")
        self.assertTrue(all(cookie.path == self.app + "/" for cookie in session_cookies), "session cookie stays within its admin application")
        anonymous_opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(anonymous))
        status, _, _ = self.request("/mcp-tokens", opener=anonymous_opener)
        self.assertEqual(status, 401, "old anonymous cookie cannot become a logged-in session")
        status, body, _ = self.request("/mcp-tokens")
        self.assertEqual(status, 200)
        self.assertEqual(body["namespace"], "PITEST")
        self.assertTrue("password" not in json.dumps(body).lower())
        old = CookieJar()
        for cookie in self.jar:
            old.set_cookie(copy.copy(cookie))
        old_opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(old))
        status, body, _ = self.request("/logout", {})
        self.assertEqual(status, 200)
        self.assertFalse(body["authenticated"])
        status, _, _ = self.request("/mcp-tokens", opener=old_opener)
        self.assertEqual(status, 401)
        status, body, _ = self.request("/session")
        self.assertFalse(body["authenticated"])

    def test_wrong_password_and_non_admin_do_not_keep_a_login(self):
        status, body, _ = self.request("/login", {"username": self.user, "password": "synthetic-wrong-password"})
        self.assertEqual(status, 401)
        self.assertEqual(body["code"], "ADMIN_LOGIN_FAILED")
        status, _, _ = self.login(self.reader)
        self.assertEqual(status, 403)
        _, body, _ = self.request("/session")
        self.assertFalse(body["authenticated"])

    def test_csrf_and_basic_auth_cannot_bypass_the_web_session(self):
        for extra in ({"Origin": "https://example.com"}, {"X-Identity-Review": ""}):
            status, _, _ = self.request("/login", {"username": self.user, "password": self.password}, extra)
            self.assertEqual(status, 403)
        self.login()
        status, _, _ = self.request("/logout", {}, {"Origin": "https://example.com"})
        self.assertEqual(status, 403)
        self.request("/logout", {})
        basic = base64.b64encode((self.user + ":" + self.password).encode()).decode()
        status, _, _ = self.request("/mcp-tokens", extra={"Authorization": "Basic " + basic})
        self.assertEqual(status, 401)

    def test_native_idle_expiry(self):
        # Configure a separate short-lived application before the first HTTP request to avoid CSP cache interference.
        original = self.app
        self.app = original + "-short"
        iris(f'try {{ set sc=##class(Security.Applications).Get({literal(original)},.p) set p("Timeout")=1,p("CookiePath")={literal(self.app + "/")} set sc=##class(Security.Applications).Create({literal(self.app)},.p) if $system.Status.IsError(sc) {{ throw ##class(%Exception.General).%New("APP_FAILED") }} write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}')
        try:
            status, state, _ = self.login()
            self.assertEqual(status, 200)
            self.assertEqual(state["idleTimeoutSeconds"], 1)
            time.sleep(2.2)
            status, _, _ = self.request("/mcp-tokens")
            self.assertEqual(status, 401)
        finally:
            iris(f'try {{ set sc=##class(Security.Applications).Delete({literal(self.app)}) write "TOKEN_FIXTURE_OK",! }} catch ex {{ write "TOKEN_FIXTURE_FAILED",! }}')
            self.app = original
