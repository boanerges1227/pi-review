"use strict";
/** Accept only a canonical case ID when navigating from the MCP dashboard. */
let selected = (() => {
  if (typeof location === "undefined") return null;
  const id = new URLSearchParams(location.search).get("case");
  return /^c[1-9]\d*$/.test(id || "") ? id : null;
})();
let current = null;
let detailRequest = 0;
const $ = id => document.getElementById(id);
const labels = {PENDING_AGENT:"Awaiting investigation", LINK_REVIEW:"Association review", SEPARATE_REVIEW:"Keep separate review", NEEDS_DATA:"Awaiting source data", CONFLICT_REVIEW:"Conflict review", APPROVED:"Approved", REJECTED:"Rejected"};

/** Use textContent for all created nodes so source text cannot become executable HTML. */
function node(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}

/** Call same-origin endpoints; include the server-required header explicitly for mutations. */
async function api(path, data) {
  const response = await fetch("/identity" + path, {method:data === undefined ? "GET" : "POST", headers:{"Content-Type":"application/json", "X-Identity-Review":"local-demo"}, body:data === undefined ? undefined : JSON.stringify(data)});
  // A session can expire after the page opens; redirect denied data requests to login and disable further actions.
  if (response.status === 401) { identityAdmin.signIn("/identity/" + (selected ? "?case=" + selected : ""));throw new Error("Your session has expired. Please sign in again."); }
  const result = await response.json();
  if (!response.ok) throw new Error(result.code || `HTTP ${response.status}`);
  return result;
}

/** Build a complete synthetic R4 message whose Patient matches the demo source registry. */
function fhirExample() {
  const patientRef = "urn:uuid:22222222-2222-4222-8222-222222222222";
  return {resourceType:"Bundle", id:"fhir-ui-demo-1", type:"message", entry:[
    {fullUrl:"urn:uuid:11111111-1111-4111-8111-111111111111", resource:{resourceType:"MessageHeader", id:"fhir-ui-header-1", eventCoding:{system:"https://example.org/fhir/CodeSystem/identity-event",code:"patient-upsert"}, source:{endpoint:"urn:pi:source:EMR"}, focus:[{reference:patientRef}]}},
    {fullUrl:patientRef, resource:{resourceType:"Patient", id:"MCP-EMR-A", meta:{versionId:"1"}, identifier:[{system:"https://example.org/fhir/identifier/synthetic-person",value:"SYN-MCP-1001"}], name:[{text:"MCP Avery Chen"}], gender:"female", birthDate:"1988-03-17", telecom:[{system:"phone",value:"TEST-PHONE-1"}]}}
  ]};
}

/** Submit the message Bundle through the FHIR operation and read its structured response parameters. */
async function submitFhir(message) {
  const response = await fetch("/identity-fhir/$process-message", {method:"POST", headers:{"Content-Type":"application/fhir+json", "X-Identity-Review":"local-demo"}, body:JSON.stringify(message)});
  const data = await response.json();
  if (!response.ok) throw new Error(data.issue?.[0]?.details?.text || `HTTP ${response.status}`);
  if (data.resourceType !== "Bundle" || data.type !== "message" || !Array.isArray(data.entry)) throw new Error("FHIR_RESPONSE_INVALID");
  const parameters = data.entry.find(item => item.resource?.resourceType === "Parameters")?.resource?.parameter;
  if (!Array.isArray(parameters)) throw new Error("FHIR_RESPONSE_INVALID");
  const get = name => parameters.find(parameter => parameter.name === name)?.valueString || "";
  return {caseId:get("caseId"),status:get("status"),recordId:get("recordId")};
}

/** Lock buttons during operations and make error feedback accessible to assistive technology. */
async function run(button, task) {
  button.disabled = true;
  const before = button.textContent;
  button.textContent = "Working…";
  $("notice").textContent = "";
  try { await task(); } catch (error) { $("notice").textContent = error.message; }
  finally { button.disabled = false; button.textContent = before; }
}

/** Update queues and budget from actual backend state without simulating investigation results in the browser. */
async function refresh() {
  const health = await api("/health");
  $("connection").textContent = `IRIS build 154 · Production ${health.productionRunning ? "running" : "stopped"} · Source MCP ${health.mcp?.status || "NOT_CHECKED"} · ${health.liveEnabled && health.modelConfig?.configured ? "Live model configured" : "Manual fallback"}`;
  $("budget").textContent = `${health.model || "No model"} · Estimate ¥${Number(health.knownEstimateCny ?? health.estimatedCny ?? 0).toFixed(2)} + unknown usage allowance ¥${Number(health.unknownUsageCny || 0).toFixed(2)} + in flight ¥${Number(health.reservedCny || 0).toFixed(2)} / ¥${health.budgetCny}`;
  const cases = await api("/cases");
  $("count").textContent = cases.length;
  $("cases").replaceChildren();
  for (const c of cases) {
    const b = node("button", null, "case" + (c.id === selected ? " selected" : ""));
    b.append(node("span", labels[c.status] || c.status, "badge" + (c.status === "APPROVED" ? " approved" : c.status === "CONFLICT_REVIEW" ? " conflict" : "")), node("strong", c.incoming.name), node("span", `${c.incoming.sourceSystem} · ${c.id} · v${c.version}`, "meta"));
    b.addEventListener("click", () => run(b, async () => {selected = c.id; await refresh();}));
    $("cases").append(b);
  }
  if (selected) await showCase(selected);
}

/** Compare two records in a fixed field order and highlight differences without changing field values. */
function comparison(c, candidate) {
  const table = node("table");
  const head = node("tr");
  ["Field", "Incoming record", "Candidate record"].forEach(x => head.append(node("th", x)));
  table.append(head);
  for (const [key, title] of [["name","Name"],["birthDate","Date of birth"],["sex","Sex"],["identifier","Synthetic identifier"],["phone","Synthetic phone"],["sourceSystem","Source"]]) {
    const a = c.incoming[key] || "Missing", b = candidate?.[key] || "—";
    const row = node("tr");
    row.append(node("td",title), node("td",a, candidate && a !== b ? "different" : ""), node("td",b, candidate && a !== b ? "different" : ""));
    table.append(row);
  }
  return table;
}

/** Display verifiable tool results and execution records without generating the model's internal chain of thought. */
function trace(title, data) {
  const d = node("details", null, "trace-entry");
  d.append(node("summary", title), node("pre", JSON.stringify(data, null, 2)));
  return d;
}

/** Submit human decisions against the current version; the server revalidates actions from stale pages. */
async function decide(snapshot, action, candidateId, reason) {
  await api(`/cases/${snapshot.id}/review`, {version:snapshot.version, action, candidateId, reason});
  await refresh();
}

/** Present evidence, model conclusions, and human decisions separately in the work item interface. */
async function showCase(id) {
  const requestId = ++detailRequest;
  const c = await api(`/cases/${id}`);
  // Late responses from older requests cannot overwrite a new selection; all mutations also bind to the rendered snapshot.
  if (id !== selected || requestId !== detailRequest) return;
  current = c;
  const root = $("detail");
  root.replaceChildren();
  const header = node("div", null, "case-header"), heading = node("div");
  heading.append(node("p", `${c.id.toUpperCase()} / IDENTITY INVESTIGATION`, "eyebrow"), node("h2", c.incoming.name));
  const investigate = node("button", "Investigate with AI Hub");
  investigate.disabled = ["APPROVED","REJECTED"].includes(c.status);
  investigate.addEventListener("click", () => run(investigate, async () => {await api(`/cases/${id}/investigate`, {}); await refresh();}));
  header.append(heading, investigate);
  root.append(header, node("p", `${labels[c.status] || c.status} · Source version ${c.incoming.sourceVersion} · ${c.correlationId} · Mode: ${c.mode}`, "case-subtitle"));
  if (c.baseline) root.append(node("p", `Rule baseline: ${labels[c.baseline.decision] || c.baseline.decision} — ${c.baseline.reason}`, "muted small"));
  if (c.result) {
    const d = node("div", null, "decision");
    d.append(node("strong", labels[c.result.decision] || c.result.decision), node("span", c.result.reasonSummary || c.result.error));
    if (c.result.error) d.append(node("p", `Validation / fallback: ${c.result.error}`));
    root.append(d);
  }
  const latestRun = c.runs.at(-1);
  if (latestRun?.usageDelta) {
    const stats = node("section", null, "investigation-stats");
    stats.append(node("strong", `Investigation ${latestRun.runId} · ${latestRun.sessionResumed ? "Session resumed" : "New session"}`));
    if (latestRun.contextReset) stats.append(node("span", "Source or policy changed · previous facts cleared · fresh evidence required"));
    stats.append(node("span", `New tokens: ${latestRun.usageDelta.total_prompt_tokens || 0} input / ${latestRun.usageDelta.total_completion_tokens || 0} output · ${latestRun.toolCalls || 0} tools · ${Math.round(latestRun.elapsedSeconds || 0)}s`));
    root.append(stats);
  }
  const select = node("select");
  select.setAttribute("aria-label", "Candidate record");
  if (!c.candidates.length) select.append(new Option("No candidate — request source enrichment", ""));
  for (const r of c.candidates) select.append(new Option(`${r.name} · ${r.sourceSystem} · ${r.id} · ${r.masterId || "not associated"}`, r.id));
  const compare = node("div");
  const renderCompare = () => compare.replaceChildren(comparison(c, c.candidates.find(x => x.id === select.value)));
  select.addEventListener("change", renderCompare);
  renderCompare();
  root.append(select, compare);
  const review = node("section", null, "block");
  review.append(node("h3", "Human review"));
  const reason = node("textarea");
  reason.placeholder = "Record the evidence you checked and why this decision is justified…";
  reason.setAttribute("aria-label", "Review reason");
  const actions = node("div", null, "review-actions");
  for (const [title, action, cls] of [["Confirm association","LINK",""],["Keep separate","SEPARATE","secondary"],["Reject change","REJECT","secondary"]]) {
    const b = node("button", title, cls);
    b.disabled = ["APPROVED","REJECTED"].includes(c.status);
    b.addEventListener("click", () => run(b, () => decide(c, action, select.value, reason.value)));
    actions.append(b);
  }
  if (c.status === "APPROVED") {
    const undo = node("button", "Undo last approval", "danger");
    undo.addEventListener("click", () => run(undo, async () => {await api(`/cases/${id}/undo`, {version:c.version, reason:reason.value}); await refresh();}));
    actions.append(undo);
  }
  if (c.status === "NEEDS_DATA" && c.enrichment?.transport === "mcp") {
    const fetchSource = node("button", "Fetch source update (MCP)", "secondary");
    fetchSource.addEventListener("click", () => run(fetchSource, async () => {
      const update = await api(`/cases/${id}/enrichment`, {version:c.version});
      await refresh();
      if (update.status === "WAITING") $("notice").textContent = "Source task is still waiting. No model request was made.";
    }));
    actions.append(fetchSource);
  }
  const enrich = node("button", "Prepare enrichment", "secondary");
  enrich.addEventListener("click", () => {
    const value = {...c.incoming, sourceVersion:c.incoming.sourceVersion + 1};
    delete value.id; delete value.masterId;
    $("payload").value = JSON.stringify(value, null, 2);
    document.querySelector(".intake-panel").open = true;
    $("payload").focus();
  });
  actions.append(enrich);
  review.append(reason, actions, node("p", "Association is a mapping change. Original records remain intact. Conflicting identifiers cannot be linked.", "review-note"));
  root.append(review);
  const evidence = node("section", null, "block");
  evidence.append(node("h3", `Evidence & execution trace · ${c.evidence.length} collected evidence items`));
  if (!c.evidence.length) evidence.append(node("p", "No evidence collected for the current case version. Historical tool calls remain in the audit trail.", "muted small"));
  for (const e of c.evidence) {
    if (e.tool === "search_governance_rules") {
      const rules = node("section", null, "governance-sources");
      rules.append(node("h4", `Governance sources · ${e.data.version} · synthetic policies`));
      for (const chunk of e.data.chunks || []) {
        rules.append(node("strong", `${chunk.metadata.source} · ${chunk.metadata.version}`), node("p", chunk.text));
      }
      evidence.append(rules);
    }
    evidence.append(trace(`${e.tool} · ${e.evidenceId} · collected at case v${e.caseVersion}`, e));
  }
  if (c.toolTrace?.length) {
    evidence.append(node("h4", "Native tool authorization & execution"));
    for (const event of c.toolTrace) evidence.append(trace(`${event.outcome} · ${event.tool} · run ${event.runId} · ${event.durationMs || 0}ms`, event));
  }
  if (c.enrichment) evidence.append(trace("Source MCP enrichment task", c.enrichment));
  for (const event of c.mcpTrace || []) evidence.append(trace(`Source MCP · ${event.tool} · ${event.outcome} · run ${event.runId || "workflow"}`, event));
  for (const r of c.runs) evidence.append(trace(`Agent run · ${r.mode} · ${r.toolCalls || 0} tools · ${Math.round(r.elapsedSeconds || 0)}s`, r));
  evidence.append(trace("Workflow & review audit", c.audit));
  root.append(evidence);
}

$("seed").addEventListener("click", () => run($("seed"), async () => {const d = await api("/demo", {}); selected ||= d.cases[0]?.id; await refresh();}));
$("refresh").addEventListener("click", () => run($("refresh"), refresh));
$("load-fhir-example").addEventListener("click", () => {$("payload").value = JSON.stringify(fhirExample(), null, 2);$("payload").focus();});
$("submit-record").addEventListener("click", () => run($("submit-record"), async () => {
  const payload = JSON.parse($("payload").value);
  if (payload.resourceType && payload.resourceType !== "Bundle") throw new Error("FHIR input must be a complete message Bundle.");
  const fhir = payload.resourceType === "Bundle";
  const result = fhir ? await submitFhir(payload) : await api("/intake", payload);
  selected = result.caseId || selected;
  await refresh();
  if (fhir) $("notice").textContent = `FHIR message processed · ${result.status} · source record ${result.recordId}${result.caseId ? ` · case ${result.caseId}` : ""}`;
}));
$("payload").value = JSON.stringify({sourceSystem:"CHECKUP",sourcePatientId:"NEW-SYNTHETIC-001",sourceVersion:1,name:"Demo Patient",birthDate:"1990-01-01",sex:"F",identifier:"SYN-3001",phone:"TEST-PHONE-3",notes:"Synthetic example only"}, null, 2);
refresh().catch(error => {$("notice").textContent = error.message;});
// The server protects the page; the client displays identity, logout and expired-session navigation.
identityAdmin.init({required:true,target:"/identity/",notice:"notice",onLogout:()=>{current=null;detailRequest++;$("detail").replaceChildren();$("payload").value="";}});
