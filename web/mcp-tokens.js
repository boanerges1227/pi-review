"use strict";
let tokenRows = [];
let tokenSelected = null;
let tokenBusy = false;
let tokenReady = false;
let tokenSessionVersion = 0;
/** Read the separate management page's elements using fixed control IDs. */
const tokenNode = id => document.getElementById(id);
const tokenMessages = {
  MCP_TOKEN_VERSION_CONFLICT:"This token changed. Reload tokens before editing again.",
  MCP_TOKEN_REVOKED:"This token has already been revoked. Reload tokens.",
  MCP_TOKEN_NOT_FOUND:"This token no longer exists. Reload tokens.",
  INVALID_MCP_CASES:"Enter up to 50 existing case IDs, separated by commas.",
  INVALID_MCP_LABEL:"Enter a label of 1 to 80 characters without control characters.",
  INVALID_MCP_EXPIRY:"Choose an expiry between 1 and 365 whole days.",
  BUSY:"Token management is busy. Reload tokens and try again."
};

/** Render labels and server fields as text only to prevent HTML injection. */
function tokenElement(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = String(text);
  if (className) element.className = className;
  return element;
}

/** Bound admin request timeouts, never retry creation automatically, and keep credentials out of logs and URLs. */
async function tokenRequest(path, data) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(path, {method:data === undefined ? "GET" : "POST", credentials:"same-origin", cache:"no-store", signal:controller.signal, headers:{"Content-Type":"application/json","X-Identity-Review":"local-demo"}, body:data === undefined ? undefined : JSON.stringify(data)});
    if (response.status === 401 || response.status === 403) { clearTokenSecret();identityAdmin.signIn("/identity/mcp-tokens");throw new Error("Your session has expired. Please sign in again."); }
    let body;
    try { body = await response.json(); } catch { throw new Error("Unexpected server response. Reload tokens before trying again."); }
    if (!response.ok) throw new Error(tokenMessages[body.code] || "Token request failed. Reload tokens before trying again.");
    return body;
  } finally { clearTimeout(timer); }
}

/** Keep missing timestamps unknown, display local time, and let the server determine expiration. */
function tokenTime(value) {
  return value > 0 ? new Date(value * 1000).toLocaleString("en-US") : "Not recorded";
}

/** Disable writes during requests, while logged out or with stale snapshots; revoked identities cannot be re-enabled. */
function tokenControls() {
  const editable = tokenReady && !tokenBusy && (!tokenSelected || tokenSelected.status === "ACTIVE");
  for (const id of ["token-label", "token-cases", "token-save"]) tokenNode(id).disabled = !editable;
  tokenNode("token-days").disabled = !editable || Boolean(tokenSelected);
  tokenNode("token-new").disabled = !tokenReady || tokenBusy;
  tokenNode("token-load").disabled = tokenBusy;
  tokenNode("token-revoke").disabled = !tokenReady || tokenBusy || !tokenSelected || tokenSelected.status === "REVOKED";
  tokenNode("token-save").textContent = tokenSelected ? "Save case access" : "Create token";
  renderTokenList();
}

/** Keep credentials only in the current display control, with no duplicate JavaScript state after clearing. */
function clearTokenSecret() {
  tokenNode("token-secret").value = "";
  tokenNode("token-once").hidden = true;
}

/** Clear the previous plaintext when switching identities; a normal refresh may retain a newly created one-time value. */
function showToken(row, preserveSecret = false) {
  if (tokenBusy && !preserveSecret) return;
  tokenSelected = row ? {...row} : null;
  if (!preserveSecret) clearTokenSecret();
  tokenNode("token-label").value = row?.label || "";
  tokenNode("token-cases").value = row?.cases.join(", ") || "";
  tokenNode("token-days").value = "30";
  tokenNode("token-form-title").textContent = row ? row.label : "Create client access";
  tokenNode("token-form-state").textContent = row ? `${row.id} · VERSION ${row.version} · ${row.status}` : "NEW TOKEN";
  tokenNode("token-expiry-note").textContent = row ? row.expiresAtEpoch ? `Expires ${tokenTime(row.expiresAtEpoch)}. Create a replacement to extend access.` : "Legacy token · no expiry. Create a replacement with an expiry and revoke this token when ready." : "Expiry is fixed at creation. Create a replacement token to extend access.";
  tokenControls();
}

/** Show actual states and explicit cases; expired identities can be viewed or revoked but not edited back into validity. */
function renderTokenList() {
  const root = tokenNode("token-list");
  root.replaceChildren();
  if (!tokenRows.length) root.append(tokenElement("p", tokenReady ? "No access tokens. Create one for your MCP client." : "Load the administrator list to manage access.", "token-subtle"));
  for (const row of tokenRows) {
    const button = tokenElement("button", undefined, "token-item" + (tokenSelected?.id === row.id ? " selected" : ""));
    button.type = "button";
    button.disabled = tokenBusy || !tokenReady;
    button.append(tokenElement("span", row.status, "token-status " + (row.status === "ACTIVE" ? "success" : "neutral")), tokenElement("strong", row.label), tokenElement("span", `${row.id} · ${row.cases.length ? row.cases.join(", ") : "No case access"}`, "token-subtle"), tokenElement("span", row.expiresAtEpoch ? `Expires ${tokenTime(row.expiresAtEpoch)}` : "Legacy · no expiry", "token-subtle"), tokenElement("span", `Last authenticated: ${tokenTime(row.lastUsedAtEpoch)}`, "token-subtle"));
    button.addEventListener("click", () => showToken(row));
    root.append(button);
  }
}

/** Never include or overwrite plaintext tokens during metadata refresh; disable writes on malformed responses. */
async function refreshTokenCatalog(preferredId = tokenSelected?.id) {
  const sessionVersion = tokenSessionVersion;
  const data = await tokenRequest("/identity/admin/mcp-tokens");
  if (sessionVersion !== tokenSessionVersion) return false;
  if (!Array.isArray(data.tokens) || !data.tokens.every(row => typeof row.id === "string" && typeof row.label === "string" && Number.isInteger(row.version) && ["ACTIVE", "EXPIRED", "REVOKED"].includes(row.status) && Array.isArray(row.cases))) throw new Error("Invalid token list. Reload before editing.");
  tokenRows = data.tokens;
  tokenReady = true;
  showToken(tokenRows.find(row => row.id === preferredId) || null, true);
  return true;
}

/** Load only on admin request; dashboard telemetry polling never reads or changes credentials. */
async function loadTokens() {
  if (tokenBusy) return;
  const sessionVersion = tokenSessionVersion;
  tokenBusy = true;tokenReady = false;tokenControls();
  try { if (!await refreshTokenCatalog()) return;tokenNode("token-notice").textContent = "Administrator list loaded. Each token can read only its assigned cases."; }
  catch (error) { if (sessionVersion === tokenSessionVersion) {tokenReady = false;tokenNode("token-notice").textContent = error.message;} }
  finally { tokenBusy = false;tokenControls(); }
}

/** Normalize case input before saving; the complete grant array replaces the ACL, and an empty array clears access. */
function readTokenForm() {
  const text = tokenNode("token-cases").value.trim();
  const cases = text ? [...new Set(text.split(",").map(value => value.trim()))] : [];
  if (cases.length > 50 || cases.some(id => !/^c[1-9]\d*$/.test(id))) throw new Error(tokenMessages.INVALID_MCP_CASES);
  const label = tokenNode("token-label").value.trim();
  if (!label || label.length > 80) throw new Error(tokenMessages.INVALID_MCP_LABEL);
  return tokenSelected ? {label, cases, version:tokenSelected.version} : {label, cases, expiresInDays:Number(tokenNode("token-days").value)};
}

/** Retain successful write results before refreshing so a failed refresh cannot hide success or lose a one-time value. */
async function saveToken() {
  if (tokenBusy || !tokenReady || (tokenSelected && tokenSelected.status !== "ACTIVE")) return;
  let data;
  try { data = readTokenForm(); } catch (error) { tokenNode("token-notice").textContent = error.message;return; }
  const creating = !tokenSelected;
  const sessionVersion = tokenSessionVersion;
  const path = "/identity/admin/mcp-tokens" + (creating ? "" : "/" + encodeURIComponent(tokenSelected.id));
  tokenBusy = true;tokenControls();
  if (creating) clearTokenSecret();
  try {
    const result = await tokenRequest(path, data);
    // Reject responses from the old session after logout begins so late creation results cannot reveal credentials again.
    if (sessionVersion !== tokenSessionVersion) return;
    const saved = creating ? result.item : result;
    tokenRows = [...tokenRows.filter(row => row.id !== saved.id), saved];
    showToken(saved, true);
    if (creating) { tokenNode("token-secret").value = result.token;tokenNode("token-once").hidden = false; }
    try { if (!await refreshTokenCatalog(saved.id)) return;tokenNode("token-notice").textContent = creating ? "Token created. Save the one-time value below now." : "Case access updated. Existing clients use the new permissions on their next call."; }
    catch { tokenReady = false;tokenNode("token-notice").textContent = creating ? "Token created, but list refresh failed. Save the one-time value below, then reload tokens." : "Case access saved, but list refresh failed. Reload tokens before editing again."; }
  } catch (error) { if (sessionVersion === tokenSessionVersion) {tokenReady = false;tokenNode("token-notice").textContent = error.message + (creating ? " The result may be unknown. Reload the list; revoke any unusable token before creating a replacement." : "");} }
  finally { tokenBusy = false;tokenControls(); }
}

/** Require confirmation and the current version for revocation; display the result and disable actions immediately. */
async function revokeToken() {
  if (tokenBusy || !tokenReady || !tokenSelected || tokenSelected.status === "REVOKED") return;
  if (!window.confirm(`Revoke access for “${tokenSelected.label}”? Clients using this token will lose access on their next call.`)) return;
  const sessionVersion = tokenSessionVersion;
  tokenBusy = true;tokenControls();
  try {
    const saved = await tokenRequest(`/identity/admin/mcp-tokens/${encodeURIComponent(tokenSelected.id)}/revoke`, {version:tokenSelected.version});
    if (sessionVersion !== tokenSessionVersion) return;
    tokenRows = tokenRows.map(row => row.id === saved.id ? saved : row);
    clearTokenSecret();showToken(saved, true);
    tokenNode("token-notice").textContent = "Token revoked. It cannot be re-enabled, including after a restart.";
  } catch (error) { tokenReady = false;tokenNode("token-notice").textContent = error.message; }
  finally { tokenBusy = false;tokenControls(); }
}

/** Copy the one-time value only on user action; retain the text if copying fails so it can be saved manually. */
async function copyToken() {
  const value = tokenNode("token-secret").value;
  if (!value) return;
  try { await navigator.clipboard.writeText(value);tokenNode("token-notice").textContent = "Token copied. Store it securely, then clear it from this page."; }
  catch { tokenNode("token-notice").textContent = "Clipboard unavailable. Select and copy the token manually before clearing it."; }
}

tokenNode("token-load").addEventListener("click", loadTokens);
tokenNode("token-new").addEventListener("click", () => { if (tokenReady && !tokenBusy) showToken(null); });
tokenNode("token-form").addEventListener("submit", event => {event.preventDefault();saveToken();});
tokenNode("token-revoke").addEventListener("click", revokeToken);
tokenNode("token-copy").addEventListener("click", copyToken);
tokenNode("token-clear").addEventListener("click", clearTokenSecret);
tokenControls();
identityAdmin.init({required:true,target:"/identity/mcp-tokens",notice:"token-notice",onAuthenticated:loadTokens,onLogout:() => {tokenSessionVersion++;clearTokenSecret();tokenReady=false;tokenRows=[];tokenSelected=null;tokenControls();}});
