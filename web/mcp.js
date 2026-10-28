"use strict";
let dashboardData = null;
let dashboardBusy = false;
let dashboardTimer = null;
let activityLimit = 50;
const mcpNode = id => document.getElementById(id);

/** Construct text-only nodes; source or tool text must never become HTML. */
function mcpElement(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined && text !== null) element.textContent = String(text);
  if (className) element.className = className;
  return element;
}

/** Preserve unavailable metrics rather than presenting an absent measurement as zero. */
function formatMetric(value, unit = "") {
  if (value === null || value === undefined || value === "" || !Number.isFinite(Number(value))) return "—";
  return Number(value).toLocaleString("en-US", {maximumFractionDigits:1}) + unit;
}

/** Old records have no reconstructed timestamp; observation age never proves current connectivity. */
function eventTime(event) {
  if (!event.timestampKnown || !Number.isFinite(Number(event.occurredAtEpoch))) return "Legacy · time unavailable";
  return new Date(event.occurredAtEpoch * 1000).toLocaleString("en-US");
}

/** Link only canonical case identifiers to the existing workbench selection. */
function caseLink(caseId) {
  if (!/^c[1-9]\d*$/.test(caseId || "")) return mcpElement("span", "—");
  const link = mcpElement("a", caseId, "mcp-case-link");
  link.href = "/identity/?case=" + encodeURIComponent(caseId);
  return link;
}

/** Render a semantic progress bar with an explicit numeric label, without inline CSS. */
function activityBar(label, count, maximum, className = "") {
  const row = mcpElement("div", null, "mcp-bar " + className);
  const heading = mcpElement("div", null, "mcp-bar-heading");
  heading.append(mcpElement("span", label), mcpElement("strong", formatMetric(count)));
  const progress = mcpElement("progress");
  progress.max = Math.max(1, maximum);
  progress.value = count;
  progress.setAttribute("aria-label", `${label}: ${count}`);
  row.append(heading, progress);
  return row;
}

/** Describe last recorded outcomes without implying that either MCP endpoint was just probed. */
function renderServers(data) {
  const root = mcpNode("server-cards");
  root.replaceChildren();
  for (const server of data.servers) {
    const event = server.observation || {};
    const success = ["OK", "ALLOWED"].includes(event.outcome);
    const failure = ["FAILED", "DENIED"].includes(event.outcome);
    const card = mcpElement("article", null, "mcp-server");
    const top = mcpElement("div", null, "mcp-server-top");
    top.append(mcpElement("span", server.id === "source" ? "↗" : "↙", "mcp-server-icon"), mcpElement("span", server.id === "source" ? "OUTBOUND" : "INBOUND", "eyebrow"));
    const badge = mcpElement("span", success ? "Last observed success" : event.outcome === "DENIED" ? "Last request denied" : failure ? "Last execution failed" : "No recorded activity", "mcp-status " + (success ? "success" : failure ? "attention" : "neutral"));
    top.append(badge);
    card.append(top, mcpElement("h3", server.name), mcpElement("p", server.role), mcpElement("code", server.endpoint), mcpElement("p", `${server.tools} configured tools · ${event.eventId ? eventTime(event) : "Awaiting a recorded call"}`, "mcp-footnote"));
    root.append(card);
  }
}

/** Keep configured source and publishing tool metrics distinguishable. */
function renderInsights(data) {
  const root = mcpNode("tool-activity");
  root.replaceChildren();
  const maximum = Math.max(1, ...data.tools.map(tool => tool.total));
  for (const tool of data.tools) {
    const row = activityBar(tool.name, tool.total, maximum, tool.direction);
    row.append(mcpElement("small", `${tool.direction === "outbound" ? "Source" : "Published"} · ${tool.ok} successful · ${tool.failed} failed / denied · avg ${formatMetric(tool.averageMs, " ms")}`, "mcp-subtle"));
    root.append(row);
  }
  const audit = data.summary.published;
  mcpNode("published-summary").textContent = `${audit.allowed} allowed · ${audit.denied} denied`;
  const verification = data.summary.verifications;
  const proof = mcpNode("verification-outcomes");
  proof.replaceChildren();
  for (const [key, label, color] of [["verified", "Verified", "verified"], ["mismatch", "Mismatch", "mismatch"], ["unknown", "Unknown source", "unknown"], ["unavailable", "Unavailable", "unavailable"]]) {
    proof.append(activityBar(label, verification[key], verification.total, color));
  }
  mcpNode("verification-total").textContent = `${verification.total} recorded verification evidence items`;
}

/** Filter only cached recorded events; searches do not execute tools or fetch other namespaces. */
function filteredEvents(data = dashboardData) {
  if (!data) return [];
  const direction = mcpNode("direction-filter").value;
  const result = mcpNode("result-filter").value;
  const tool = mcpNode("tool-filter").value;
  const query = mcpNode("case-filter").value.trim().toLowerCase();
  return data.events.filter(event => {
    const success = ["OK", "ALLOWED"].includes(event.outcome);
    return (direction === "all" || event.direction === direction)
      && (result === "all" || (result === "success" ? success : !success))
      && (tool === "all" || event.tool === tool)
      && (!query || event.caseId.toLowerCase().includes(query));
  }).sort((a, b) => {
    if (a.timestampKnown && b.timestampKnown) return b.occurredAtEpoch - a.occurredAtEpoch || b.eventId - a.eventId;
    if (Boolean(a.timestampKnown) !== Boolean(b.timestampKnown)) return a.timestampKnown ? -1 : 1;
    return a.direction.localeCompare(b.direction) || b.eventId - a.eventId;
  });
}

/** Render bounded event rows and explicit empty states; unknown legacy times stay visible. */
function renderEvents(data = dashboardData) {
  const events = filteredEvents(data);
  const root = mcpNode("activity-body");
  root.replaceChildren();
  for (const event of events.slice(0, activityLimit)) {
    const row = mcpElement("tr");
    const tool = mcpElement("td");
    tool.append(mcpElement("span", event.direction === "outbound" ? "Source MCP" : "Published tool", "mcp-cell-meta"), mcpElement("code", event.tool));
    const context = mcpElement("td");
    context.append(caseLink(event.caseId), mcpElement("span", [event.caseVersion ? `v${event.caseVersion}` : "", event.runId ? `run ${event.runId}` : ""].filter(Boolean).join(" · "), "mcp-cell-meta"));
    const outcome = mcpElement("td");
    outcome.append(mcpElement("span", event.outcome, "mcp-status " + (["OK", "ALLOWED"].includes(event.outcome) ? "success" : "attention")));
    row.append(mcpElement("td", eventTime(event), "mcp-event-time"), tool, context, outcome, mcpElement("td", formatMetric(event.latencyMs, " ms")));
    root.append(row);
  }
  if (!events.length) {
    const row = mcpElement("tr");
    const empty = mcpElement("td", data?.events.length ? "No recorded activity matches these filters." : "No MCP activity has been recorded yet.", "mcp-empty");
    empty.colSpan = 5;
    row.append(empty);
    root.append(row);
  }
  mcpNode("activity-count").textContent = `${Math.min(events.length, activityLimit)} shown / ${events.length} matching`;
  mcpNode("activity-more").hidden = events.length <= activityLimit;
}

/** Show active and historical source tasks without confusing a superseded READY task with current work. */
function renderTasks(data) {
  const root = mcpNode("task-body");
  root.replaceChildren();
  for (const task of data.tasks) {
    const row = mcpElement("tr");
    const id = mcpElement("td");
    id.append(caseLink(task.caseId));
    row.append(id, mcpElement("td", `${task.originVersion || "—"} → ${task.waitingVersion || "—"}`), mcpElement("td", task.status), mcpElement("td", task.active ? "Active" : "Historical"), mcpElement("td", task.hasReceipt ? "Recorded" : "Not recorded"));
    root.append(row);
  }
  if (!data.tasks.length) {
    const row = mcpElement("tr"), empty = mcpElement("td", "No MCP enrichment tasks recorded.", "mcp-empty");
    empty.colSpan = 5;row.append(empty);root.append(row);
  }
  const tasks = data.summary.enrichment;
  mcpNode("task-summary").textContent = `${tasks.active} active · ${tasks.applied} applied · ${tasks.failed} failed · ${tasks.superseded} superseded`;
  mcpNode("task-limit").textContent = `${data.tasks.length} displayed / ${tasks.total} scanned MCP tasks. Up to ${data.scan.taskLimit} rows. ${tasks.legacy} legacy simulator tasks excluded from MCP metrics.`;
}

/** Populate the entire dashboard from one server snapshot and disclose any scan bound. */
function renderDashboard(data) {
  mcpNode("metric-calls").textContent = formatMetric(data.summary.outbound.total);
  mcpNode("metric-success").textContent = formatMetric(data.summary.outbound.successRate, "%");
  mcpNode("metric-latency").textContent = formatMetric(data.summary.outbound.p95Ms, " ms");
  mcpNode("metric-active").textContent = formatMetric(data.summary.enrichment.active);
  mcpNode("calls-detail").textContent = `${data.summary.outbound.ok} successful · ${data.summary.outbound.failed} failed`;
  mcpNode("snapshot-status").textContent = `${data.namespace} · Production ${data.productionRunning ? "running" : "stopped"} · Snapshot ${new Date(data.generatedAtEpoch * 1000).toLocaleTimeString("en-US")}`;
  const partial = Object.entries(data.scan.truncated).filter(([, value]) => value).map(([name]) => name);
  mcpNode("dashboard-notice").textContent = partial.length ? `Partial scan: ${partial.join(", ")}. Metrics cover at most ${data.scan.limitPerCollection.toLocaleString("en-US")} records per collection; activity shows the scanned scope.` : "";
  renderServers(data);renderInsights(data);renderEvents(data);renderTasks(data);
}

/** Keep a single scheduled refresh; hidden tabs and disabled polling do not enqueue new requests. */
function scheduleDashboard() {
  if (dashboardTimer !== null) clearTimeout(dashboardTimer);
  dashboardTimer = null;
  const enabled = mcpNode("auto-refresh").checked;
  mcpNode("refresh-state").textContent = document.hidden ? "Auto refresh paused · hidden tab" : enabled ? "Auto refresh · 15s · read-only" : "Manual refresh · read-only";
  if (enabled && !document.hidden && !dashboardBusy) dashboardTimer = setTimeout(loadDashboard, 15000);
}

/** Validate every field consumed by renderers before mutating the visible or cached snapshot. */
function validateDashboard(data) {
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const number = value => typeof value === "number" && Number.isFinite(value);
  const metric = value => value === null || value === "" || number(value);
  const text = value => typeof value === "string";
  const flag = value => typeof value === "boolean" || value === 0 || value === 1;
  const event = value => object(value) && number(value.eventId) && ["outbound", "inbound"].includes(value.direction)
    && text(value.tool) && text(value.outcome) && text(value.caseId) && number(value.caseVersion) && number(value.runId)
    && flag(value.timestampKnown) && (value.timestampKnown ? number(value.occurredAtEpoch) : value.occurredAtEpoch === null || value.occurredAtEpoch === undefined)
    && metric(value.latencyMs);
  const groups = {outbound:["total", "ok", "failed", "successRate", "averageMs", "p95Ms"], published:["total", "allowed", "denied", "failed"], verifications:["total", "verified", "mismatch", "unknown", "unavailable"], enrichment:["total", "active", "applied", "failed", "superseded", "legacy"]};
  if (!object(data) || !text(data.namespace) || !number(data.generatedAtEpoch) || !flag(data.productionRunning) || !object(data.summary)
    || !Object.entries(groups).every(([name, fields]) => object(data.summary[name]) && fields.every(field => ["successRate", "averageMs", "p95Ms"].includes(field) ? metric(data.summary[name][field]) : number(data.summary[name][field])))
    || !object(data.scan) || !object(data.scan.truncated) || !number(data.scan.limitPerCollection) || !number(data.scan.taskLimit)
    || !Array.isArray(data.events) || !data.events.every(event)
    || !Array.isArray(data.servers) || !data.servers.every(server => object(server) && text(server.id) && text(server.name) && text(server.role) && text(server.endpoint) && number(server.tools) && object(server.observation) && (server.observation.eventId === undefined || event(server.observation)))
    || !Array.isArray(data.tools) || !data.tools.every(tool => object(tool) && text(tool.name) && ["outbound", "inbound"].includes(tool.direction) && [tool.total, tool.ok, tool.failed].every(number) && metric(tool.averageMs))
    || !Array.isArray(data.tasks) || !data.tasks.every(task => object(task) && text(task.caseId) && text(task.status) && number(task.originVersion) && number(task.waitingVersion) && flag(task.active) && flag(task.hasReceipt))) {
    throw new Error("Invalid dashboard response");
  }
}

/** Serialize bounded GET refreshes and preserve the prior snapshot on transport or schema failures. */
async function loadDashboard() {
  if (dashboardBusy) return;
  dashboardBusy = true;
  if (dashboardTimer !== null) clearTimeout(dashboardTimer);
  dashboardTimer = null;
  mcpNode("dashboard-refresh").disabled = true;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch("/identity/mcp-data", {method:"GET", cache:"no-store", signal:controller.signal});
    // Redirect expired polling sessions to login rather than presenting authentication failure as a telemetry error.
    if (response.status === 401) { dashboardData=null;identityAdmin.signIn("/identity/mcp");throw new Error("Your session has expired. Please sign in again."); }
    if (!response.ok) throw new Error("Dashboard request failed");
    const data = await response.json();
    validateDashboard(data);
    renderDashboard(data);
    dashboardData = data;
  } catch (error) {
    if (dashboardData) {
      try { renderDashboard(dashboardData); } catch (renderError) { /* Keep the last committed cache available for the next retry. */ }
    }
    mcpNode("dashboard-notice").textContent = dashboardData ? "Could not refresh. Showing the previous snapshot; data may be stale. Use Refresh data to retry." : "Telemetry is unavailable. Use Refresh data to retry.";
    if (!dashboardData) mcpNode("snapshot-status").textContent = "No telemetry snapshot available";
  } finally {
    clearTimeout(timeout);dashboardBusy = false;mcpNode("dashboard-refresh").disabled = false;scheduleDashboard();
  }
}

mcpNode("dashboard-refresh").addEventListener("click", loadDashboard);
mcpNode("auto-refresh").addEventListener("change", scheduleDashboard);
for (const id of ["direction-filter", "result-filter", "tool-filter", "case-filter"]) {
  mcpNode(id).addEventListener(id === "case-filter" ? "input" : "change", () => {activityLimit = 50;renderEvents();});
}
mcpNode("activity-more").addEventListener("click", () => {activityLimit += 50;renderEvents();});
document.addEventListener("visibilitychange", () => {scheduleDashboard();if (!document.hidden && mcpNode("auto-refresh").checked) loadDashboard();});
loadDashboard();
// All four pages share site login; logout cancels refresh timers and clears telemetry caches.
identityAdmin.init({required:true,target:"/identity/mcp",notice:"dashboard-notice",onLogout:()=>{dashboardData=null;clearTimeout(dashboardTimer);dashboardTimer=null;}});
