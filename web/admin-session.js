"use strict";
const identityAdmin = (() => {
  let options = {}, logoutBusy = false;
  const messages = {ADMIN_LOGIN_FAILED:"The username or password is incorrect, or the account cannot sign in.",ADMIN_PERMISSION_REQUIRED:"This account does not have administrator permissions.",ADMIN_NEW_SESSION_REQUIRED:"The login session has changed. Please sign in again.",ADMIN_AUTHENTICATION_REQUIRED:"Your session has expired. Please sign in again.",FORBIDDEN:"The request failed a security check. Refresh the page and try again."};

  /** Restrict return targets to application pages and canonical case links, never external URLs. */
  function safeTarget(value) { return (["/identity/", "/identity/mcp", "/identity/mcp-tokens", "/identity/settings", "/identity/production"].includes(value) || /^\/identity\/\?case=c[1-9]\d*$/.test(value || "")) ? value : "/identity/"; }

  /** Call native session endpoints with same-origin cookies; passwords appear only in the transient login POST body. */
  async function request(path, data) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch("/identity" + path, {method:data === undefined ? "GET" : "POST", credentials:"same-origin", cache:"no-store", signal:controller.signal, headers:{"Content-Type":"application/json", "X-Identity-Review":"local-demo"}, body:data === undefined ? undefined : JSON.stringify(data)});
      let body;
      try { body = await response.json(); } catch { throw new Error("The server returned an invalid response. Please try again."); }
      if (!response.ok) { const error = new Error(messages[body.code] || "The request failed. Please try again.");error.code = body.code;throw error; }
      return body;
    } catch (error) {
      if (error.name === "AbortError") throw new Error("The request timed out. Please try again.");
      throw error;
    } finally { clearTimeout(timer); }
  }

  /** Navigate to login using fixed return targets without triggering browser Basic authentication prompts. */
  function signIn(target = options.target) { window.location.replace("/identity/login?returnTo=" + encodeURIComponent(safeTarget(target))); }

  /** Display the current user as text; the server always rechecks permissions. */
  function render(state) {
    const user = document.getElementById("admin-user"), login = document.getElementById("admin-login"), logout = document.getElementById("admin-logout");
    if (user) user.textContent = state.authenticated ? "Signed in as: " + state.username : "Not signed in";
    if (login) login.hidden = Boolean(state.authenticated);
    if (logout) logout.hidden = !state.authenticated;
  }

  /** Clear page secrets before logout and await server confirmation; allow retries without falsely reporting success. */
  async function logout() {
    if (logoutBusy) return;
    logoutBusy = true;
    const button = document.getElementById("admin-logout");
    if (button) button.disabled = true;
    options.onLogout?.();
    try { await request("/logout", {});render({authenticated:false});signIn(); }
    catch (error) { const notice = document.getElementById(options.notice || "login-notice");if (notice) notice.textContent = "Sign-out failed: " + error.message; }
    finally { logoutBusy = false;if (button) button.disabled = false; }
  }

  /** Read the actual session on admin page startup and redirect anonymous users to the site login page. */
  async function init(config = {}) {
    options = config;
    document.getElementById("admin-logout")?.addEventListener("click", logout);
    try {
      const state = await request("/session");
      if (typeof state.authenticated !== "boolean" || (state.authenticated && typeof state.username !== "string")) throw new Error("Unable to verify your session. Refresh the page to try again.");
      render(state);
      if (!state.authenticated && config.required) { signIn();return; }
      if (state.authenticated) await config.onAuthenticated?.();
    } catch (error) { render({authenticated:false});const notice = document.getElementById(config.notice);if (notice) notice.textContent = error.message; }
  }

  return {request, safeTarget, signIn, init, logout};
})();
