Class PI.REST Extends %CSP.REST
{
Parameter CHARSET = "utf-8";
Parameter HandleCorsRequest = 0;
Parameter UseSession As Integer = 1;
XData UrlMap
{
<Routes>
  <Route Url="/mcp" Method="GET" Call="MCPDashboard"/>
  <Route Url="/login" Method="GET" Call="LoginPage"/>
  <Route Url="/login" Method="POST" Call="Login"/>
  <Route Url="/logout" Method="POST" Call="Logout"/>
  <Route Url="/session" Method="GET" Call="Session"/>
  <Route Url="/admin/models" Method="POST" Call="SaveModel"/>
  <Route Url="/admin/models/:id/activate" Method="POST" Call="ActivateModel"/>
  <Route Url="/admin/mcp-tokens" Method="GET" Call="TokenCatalog"/>
  <Route Url="/admin/mcp-tokens" Method="POST" Call="CreateToken"/>
  <Route Url="/admin/mcp-tokens/:id" Method="POST" Call="UpdateToken"/>
  <Route Url="/admin/mcp-tokens/:id/revoke" Method="POST" Call="RevokeToken"/>
  <Route Url="/login.js" Method="GET" Call="LoginScript"/>
  <Route Url="/login.css" Method="GET" Call="LoginStyle"/>
  <Route Url="/admin-session.js" Method="GET" Call="AdminSessionScript"/>
  <Route Url="/mcp-data" Method="GET" Call="MCPTelemetry"/>
  <Route Url="/mcp.js" Method="GET" Call="MCPScript"/>
  <Route Url="/mcp-tokens.js" Method="GET" Call="MCPTokenScript"/>
  <Route Url="/mcp-tokens" Method="GET" Call="MCPTokens"/>
  <Route Url="/mcp-tokens.css" Method="GET" Call="MCPTokenStyle"/>
  <Route Url="/mcp.css" Method="GET" Call="MCPStyle"/>
  <Route Url="/health" Method="GET" Call="Health"/>
  <Route Url="/" Method="GET" Call="Index"/>
  <Route Url="/app.js" Method="GET" Call="Script"/>
  <Route Url="/settings" Method="GET" Call="Settings"/>
  <Route Url="/settings.js" Method="GET" Call="SettingsScript"/>
  <Route Url="/model-settings" Method="GET" Call="ModelSettings"/>
  <Route Url="/style.css" Method="GET" Call="Style"/>
  <Route Url="/cases" Method="GET" Call="Cases"/>
  <Route Url="/cases/:id" Method="GET" Call="Detail"/>
  <Route Url="/intake" Method="POST" Call="Intake"/>
  <Route Url="/demo" Method="POST" Call="Demo"/>
  <Route Url="/cases/:id/investigate" Method="POST" Call="Investigate"/>
  <Route Url="/cases/:id/enrichment" Method="POST" Call="FetchEnrichment"/>
  <Route Url="/cases/:id/review" Method="POST" Call="Review"/>
  <Route Url="/cases/:id/undo" Method="POST" Call="Undo"/>
</Routes>
}

/// Check the native session before dispatch; redirect pages to login and return JSON 401 for data requests.
ClassMethod OnPreDispatch(pUrl As %String, pMethod As %String, ByRef pContinue As %Boolean) As %Status
{
    set %response.UseHttpOnly=1
    do ..SetResponseHeaderIfEmpty("Cache-Control","no-store")
    set pContinue=1,path=pUrl
    if $extract(path,1)'="/" { set path="/"_path }
    // Expose only login, session endpoints and fixed static assets; protect business JSON, writes and admin data.
    set public=$listfromstring("/login,/logout,/session,/login.js,/login.css,/admin-session.js,/style.css,/app.js,/settings.js,/mcp.js,/mcp.css,/mcp-tokens.js,/mcp-tokens.css")
    if '$listfind(public,path) {
        set state=##class(PI.AdminSession).Current()
        if 'state.authenticated {
            // End invalid sessions after rejection to prevent cached Basic identities or anonymous requests from occupying session licenses.
            do ##class(PI.AdminSession).End()
            if (pMethod="GET"),$listfind($listfromstring("/,/mcp,/mcp-tokens,/settings"),path) {
                set target="/identity"_path
                set caseId=$get(%request.Data("case",1))
                if (path="/"),$match(caseId,"^c[1-9][0-9]*$") { set target=target_"?case="_caseId }
                set %response.Redirect="/identity/login?returnTo="_$zconvert(target,"O","URL")
            } else { do ..RespondError("ADMIN_AUTHENTICATION_REQUIRED") }
            set pContinue=0
            quit 1
        }
    }
    quit 1
}

/// Reuse native admin login, logout and status handling for the site's web session.
ClassMethod Login() As %Status { quit ##class(PI.ConfigREST).Login() }
/// End the native site session on logout, invalidating all pages and business endpoints.
ClassMethod Logout() As %Status { quit ##class(PI.ConfigREST).Logout() }
/// Return minimal identity data for the four pages to display the account and handle expiry.
ClassMethod Session() As %Status { quit ##class(PI.ConfigREST).Session() }
/// Reuse permission, same-origin and version checks for admin writes without introducing a bypass.
ClassMethod SaveModel() As %Status { quit ##class(PI.ConfigREST).Save() }
/// Require server-side checks of the current configuration version and runtime state when activating a model.
ClassMethod ActivateModel(id As %String) As %Status { quit ##class(PI.ConfigREST).Activate(id) }
/// Use the protected metadata projection for the token directory.
ClassMethod TokenCatalog() As %Status { quit ##class(PI.ConfigREST).Tokens() }
/// Return the complete token only once upon creation.
ClassMethod CreateToken() As %Status { quit ##class(PI.ConfigREST).CreateToken() }
/// Apply existing version checks to authorization changes.
ClassMethod UpdateToken(id As %String) As %Status { quit ##class(PI.ConfigREST).UpdateToken(id) }
/// Token revocation takes effect immediately.
ClassMethod RevokeToken(id As %String) As %Status { quit ##class(PI.ConfigREST).RevokeToken(id) }

/// Return the actual runtime version and SDK state instead of a hardcoded health conclusion.
ClassMethod Health() As %Status
{
    set %response.ContentType="application/json"
    set running=##class(Ens.Director).IsProductionRunning()
    set data={"version":($zversion),"aiHubAvailable":(##class(%Dictionary.ClassDefinition).%ExistsId("%AI.Agent")),"productionRunning":(running),"liveEnabled":($system.Util.GetEnviron("PI_LIVE_ENABLED")="1"),"model":($system.Util.GetEnviron("PI_MODEL")),"reservedCny":($get(^PIBudget($namespace,"reservedCny"),0)),"estimatedCny":($get(^PIBudget($namespace,"spentCny"),0)),"budgetCny":30}
    set data.unknownUsageCny=$get(^PIBudget($namespace,"unknownCny")),data.knownEstimateCny=data.estimatedCny-data.unknownUsageCny
    set data.modelConfig=##class(PI.ModelConfig).Public(),data.model=data.modelConfig.model
    set data.mcp=$select($data(^PIData($namespace,"mcpHealth")):{}.%FromJSON($get(^PIData($namespace,"mcpHealth"))),1:{"status":"NOT_CHECKED","server":"synthetic-source"})
    write data.%ToJSON()
    quit 1
}

/// Return consistent JSON without leaking stack traces or model configuration through error pages.
ClassMethod Json(data As %DynamicAbstractObject) As %Status
{
    set %response.ContentType="application/json"
    do ..SetResponseHeaderIfEmpty("Cache-Control","no-store")
    do %response.SetHeader("X-Content-Type-Options","nosniff")
    write data.%ToJSON()
    quit 1
}

/// Map only controlled error codes; unexpected errors must not reveal internal execution paths.
ClassMethod RespondError(code As %String) As %Status
{
    set status=400
    if (code="NOT_FOUND")!(code="MODEL_PROFILE_NOT_FOUND") { set status=404 }
    if (code="STALE_CASE")!(code="VERSION_CONFLICT")!(code="STALE_SOURCE_VERSION")!(code="CASE_CLOSED") { set status=409 }
    if (code="CONFIG_VERSION_CONFLICT")!(code="MODEL_CONFIG_BUSY") { set status=409 }
    if code="MCP_TOKEN_NOT_FOUND" { set status=404 }
    if (code="MCP_TOKEN_VERSION_CONFLICT")!(code="MCP_TOKEN_REVOKED") { set status=409 }
    if code="MODEL_CONFIG_SAVE_FAILED" { set status=500 }
    if code="FORBIDDEN" { set status=403 }
    if (code="ADMIN_AUTHENTICATION_REQUIRED")!(code="ADMIN_LOGIN_FAILED") { set status=401 }
    if code="ADMIN_NEW_SESSION_REQUIRED" { set status=409 }
    if code="ADMIN_PERMISSION_REQUIRED" { set status=403 }
    if (code="BUSY")!(code="PRODUCTION_UNAVAILABLE") { set status=503 }
    if $extract(code,1)="<" { set status=500,code="INTERNAL_ERROR" }
    set %response.Status=status_" "_$select(status=400:"Bad Request",status=401:"Unauthorized",status=403:"Forbidden",status=404:"Not Found",status=409:"Conflict",status=503:"Service Unavailable",1:"Internal Server Error")
    quit ..Json({"code":(code)})
}

/// Require a custom header and local same origin for browser mutations; limit incoming payloads to 64 KiB.
ClassMethod Body() As %DynamicObject
{
    if %request.GetCgiEnv("HTTP_X_IDENTITY_REVIEW")'="local-demo" { throw ##class(%Exception.General).%New("FORBIDDEN") }
    set origin=%request.GetCgiEnv("HTTP_ORIGIN"),host=%request.GetCgiEnv("HTTP_HOST")
    if (origin'="")&&(origin'=("http://"_host)) { throw ##class(%Exception.General).%New("FORBIDDEN") }
    if '$isobject(%request.Content) { throw ##class(%Exception.General).%New("INVALID_JSON") }
    if %request.Content.Size>65536 { throw ##class(%Exception.General).%New("INPUT_TOO_LARGE") }
    try { set data={}.%FromJSON(%request.Content) } catch ex { throw ##class(%Exception.General).%New("INVALID_JSON") }
    if 'data.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("INVALID_INPUT") }
    quit data
}

/// Send requests through Production and convert business errors to standard HTTP responses.
ClassMethod Submit(input As %DynamicObject) As %DynamicObject
{
    set sc=##class(Ens.Director).CreateBusinessService("Intake",.service)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
    set sc=service.Submit(input,.result)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
    if result.%IsDefined("code") { throw ##class(%Exception.General).%New(result.code) }
    quit result
}

/// Receive source messages; deduplicate network retries with the business idempotency key.
ClassMethod Intake() As %Status
{
    try { set result=..Submit(..Body()) } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Advance timed-out demo enrichment tasks when refreshing the list.
ClassMethod Cases() As %Status
{
    try { do ##class(PI.Route).Expire() set result=##class(PI.Store).List() } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Include evidence provenance and the actual execution mode in work item details.
ClassMethod Detail(id As %String) As %Status
{
    try { set result=##class(PI.Store).Detail(id) } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Retrieve source updates through the same Production intake used by incoming messages.
ClassMethod FetchEnrichment(id As %String) As %Status
{
    try { set body=..Body(),result=..Submit({"action":"fetch-enrichment","caseId":(id),"version":(body.%Get("version",0))}) } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Explicitly trigger a real model investigation within the persisted budget.
ClassMethod Investigate(id As %String) As %Status
{
    try { set body=..Body(),result=..Submit({"action":"investigate","caseId":(id)}) } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Require the case version and an action reason for human review.
ClassMethod Review(id As %String) As %Status
{
    try {
        set b=..Body(),result=##class(PI.Review).Decide(id,b.%Get("version"),b.%Get("action"),b.%Get("candidateId"),b.%Get("reason"))
    } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Explicitly undo the latest reversible confirmation, subject to version checks.
ClassMethod Undo(id As %String) As %Status
{
    try { set b=..Body(),result=##class(PI.Review).Undo(id,b.%Get("version"),b.%Get("reason")) } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Load fixed synthetic scenarios without calling a model.
ClassMethod Demo() As %Status
{
    try { set b=..Body(),result=##class(PI.Fixtures).Seed() } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Serve only fixed static resources; user input cannot control file paths.
ClassMethod Asset(name As %String, mime As %String) As %Status
{
    set %response.ContentType=mime
    do %response.SetHeader("Content-Security-Policy","default-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'")
    set stream=##class(%Stream.FileCharacter).%New()
    set stream.TranslateTable="UTF8"
    set sc=stream.LinkToFile("/workspace/web/"_name)
    if $system.Status.IsError(sc) { quit ..RespondError("NOT_FOUND") }
    while 'stream.AtEnd { write stream.Read(32767) }
    quit 1
}

/// Serve the passive MCP dashboard from a fixed project asset.
ClassMethod MCPDashboard() As %Status { quit ..Asset("mcp.html","text/html; charset=utf-8") }
/// Serve the dashboard interaction script without accepting a browser-controlled file path.
ClassMethod MCPScript() As %Status { quit ..Asset("mcp.js","application/javascript") }
/// Serve the dashboard stylesheet under the existing same-origin CSP.
ClassMethod MCPStyle() As %Status { quit ..Asset("mcp.css","text/css") }
/// Read only the current namespace telemetry; query parameters cannot choose another namespace or execute tools.
ClassMethod MCPTelemetry() As %Status
{
    try { set result=##class(PI.MCP.Dashboard).Snapshot() } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Review workbench entry point.
ClassMethod Index() As %Status { quit ..Asset("index.html","text/html; charset=utf-8") }
/// Browser interaction script.
ClassMethod Script() As %Status { quit ..Asset("app.js","application/javascript") }
/// Workbench stylesheet.
ClassMethod Style() As %Status { quit ..Asset("style.css","text/css") }
/// Reuse the workbench CSP and fixed resource mapping for the separate settings page.
ClassMethod Settings() As %Status { quit ..Asset("settings.html","text/html; charset=utf-8") }
/// Serve the settings script from a fixed file; the browser cannot supply a path.
ClassMethod SettingsScript() As %Status { quit ..Asset("settings.js","application/javascript") }
/// Unauthenticated browsers read only labels, models, endpoints, and key-presence flags; never resolve secrets.
ClassMethod ModelSettings() As %Status
{
    try { set result=##class(PI.ModelSettings).Catalog() } catch ex { return ..RespondError(ex.Name) }
    quit ..Json(result)
}

/// Serve the token management script from a fixed path without accepting arbitrary file paths.
ClassMethod MCPTokenScript() As %Status { quit ..Asset("mcp-tokens.js","application/javascript") }
/// Serve a separate token management page without dashboard scripts or telemetry polling.
ClassMethod MCPTokens() As %Status { quit ..Asset("mcp-tokens.html","text/html; charset=utf-8") }
/// Load management styles from a fixed file under the existing same-origin content security policy.
ClassMethod MCPTokenStyle() As %Status { quit ..Asset("mcp-tokens.css","text/css") }

/// Serve the login page and fixed assets publicly; account authentication remains in the separate admin application.
ClassMethod LoginPage() As %Status { do ..SetResponseHeaderIfEmpty("Cache-Control","no-store") quit ..Asset("login.html","text/html; charset=utf-8") }
/// Serve login form logic from a fixed path without accepting arbitrary file paths.
ClassMethod LoginScript() As %Status { quit ..Asset("login.js","application/javascript") }
/// Keep the login layout consistent with the workbench.
ClassMethod LoginStyle() As %Status { quit ..Asset("login.css","text/css") }
/// Share session checks and logout logic across admin pages without storing credentials.
ClassMethod AdminSessionScript() As %Status { quit ..Asset("admin-session.js","application/javascript") }
}
