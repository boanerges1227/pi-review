"use strict";
const loginTarget = identityAdmin.safeTarget(new URLSearchParams(window.location.search).get("returnTo"));
let loginBusy = true;

/** Freeze form values during login to prevent duplicate submissions or in-flight requests reading a new password. */
function loginControls() {
  for (const id of ["login-username", "login-password", "login-submit"]) document.getElementById(id).disabled = loginBusy;
  document.getElementById("login-submit").textContent = loginBusy ? "Please wait…" : "Sign in";
}

/** End the old anonymous session before logging in to a new IRIS session; never retry passwords automatically. */
async function submitLogin() {
  if (loginBusy) return;
  const username = document.getElementById("login-username").value.trim();
  const data = {username, password:document.getElementById("login-password").value};
  if (!username || !data.password) { document.getElementById("login-notice").textContent = "Enter your username and password.";return; }
  loginBusy = true;loginControls();document.getElementById("login-password").value = "";document.getElementById("login-notice").textContent = "Signing in…";
  try {
    await identityAdmin.request("/logout", {});
    const state = await identityAdmin.request("/login", data);
    if (!state.authenticated) throw new Error("Sign-in did not complete. Please enter your password again.");
    window.location.replace(loginTarget);
  } catch (error) { document.getElementById("login-notice").textContent = error.message; }
  finally { data.password = "";document.getElementById("login-password").value = "";loginBusy = false;loginControls(); }
}

/** Return signed-in admins to the fixed target; retain the login form for manual retry if the status check fails. */
async function initLogin() {
  loginControls();
  try { const state = await identityAdmin.request("/session");if (state.authenticated) window.location.replace(loginTarget); }
  catch { document.getElementById("login-notice").textContent = "Unable to verify your session. Enter your credentials to sign in."; }
  finally { loginBusy = false;loginControls(); }
}

document.getElementById("login-form").addEventListener("submit", event => {event.preventDefault();submitLogin();});
initLogin();

/** Read the cumulative public page views independently so statistics errors never disable sign-in. */
async function loadVisitStats() {
  const count = document.getElementById("public-visit-count");
  try {
    const stats = await identityAdmin.request("/visit-stats");
    if (stats.metric !== "public-login-page-views" || !Number.isSafeInteger(stats.total) || stats.total < 0) throw new Error("Invalid visit count");
    count.textContent = new Intl.NumberFormat("en-US").format(stats.total);
  } catch { count.textContent = "Unavailable"; }
}

loadVisitStats();
