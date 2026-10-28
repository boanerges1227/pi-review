Class PI.ConfigREST Extends %CSP.REST
{
Parameter CHARSET = "utf-8";
Parameter HandleCorsRequest = 0;
Parameter UseSession As Integer = 1;
XData UrlMap
{
<Routes>
  <Route Url="/" Method="GET" Call="Home"/>
  <Route Url="/session" Method="GET" Call="Session"/>
  <Route Url="/login" Method="POST" Call="Login"/>
  <Route Url="/logout" Method="POST" Call="Logout"/>
  <Route Url="/models" Method="POST" Call="Save"/>
  <Route Url="/models/:id/activate" Method="POST" Call="Activate"/>
  <Route Url="/mcp-tokens" Method="GET" Call="Tokens"/>
  <Route Url="/mcp-tokens" Method="POST" Call="CreateToken"/>
  <Route Url="/mcp-tokens/:id" Method="POST" Call="UpdateToken"/>
  <Route Url="/mcp-tokens/:id/revoke" Method="POST" Call="RevokeToken"/>
</Routes>
}

/// Enable HttpOnly before issuing the native session cookie while retaining inherited REST dispatch and input handling.
ClassMethod OnPreHTTP() As %Boolean
{
    set %response.UseHttpOnly=1
    quit ##super()
}

/// Redirect the old admin entry to the site login page without issuing a Basic authentication challenge.
ClassMethod Home() As %Status
{
    do %response.SetHeader("Cache-Control","no-store")
    set state=##class(PI.AdminSession).Current()
    set %response.Redirect=$select(state.authenticated:"/identity/mcp-tokens",1:"/identity/login")
    quit 1
}

/// Return only login status and the current account without exposing cookies, session IDs or internal permissions.
ClassMethod Session() As %Status { quit ##class(PI.REST).Json(##class(PI.AdminSession).Current()) }

/// Validate the same origin and required request header before native IRIS session authentication.
ClassMethod Login() As %Status
{
    try { set result=##class(PI.AdminSession).Login(##class(PI.REST).Body()) } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Use a protected POST for logout to prevent cross-site links from ending sessions.
ClassMethod Logout() As %Status
{
    try { set body=##class(PI.REST).Body(),result=##class(PI.AdminSession).Logout() } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Require native identity, same origin, and a custom header for admin writes to prevent cross-site use of logged-in administrators.
ClassMethod Save() As %Status
{
    try {
        do ##class(PI.AdminSession).Require()
        set body=##class(PI.REST).Body(),result=##class(PI.ModelSettings).Save(body)
    } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Activation accepts only the version read by the current page; the backend rechecks scope and in-flight operations.
ClassMethod Activate(id As %String) As %Status
{
    try {
        do ##class(PI.AdminSession).Require()
        set body=##class(PI.REST).Body(),result=##class(PI.ModelSettings).Activate(id,body.%Get("version",-1))
    } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Return token listings only through the native admin application; anonymous dashboards cannot read authorization metadata.
ClassMethod Tokens() As %Status
{
    try { do ##class(PI.AdminSession).Require() set result=##class(PI.MCP.Tokens).Catalog() } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Validate the admin and same-origin request before creation; return the complete token only in this response.
ClassMethod CreateToken() As %Status
{
    try {
        do ##class(PI.AdminSession).Require()
        set result=##class(PI.MCP.Tokens).Create(##class(PI.REST).Body())
    } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Accept only label, case list and version updates; reject custom hashes, identities or admin permissions.
ClassMethod UpdateToken(id As %String) As %Status
{
    try {
        do ##class(PI.AdminSession).Require()
        set result=##class(PI.MCP.Tokens).Update(id,##class(PI.REST).Body())
    } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}

/// Apply admin authentication, header, same-origin and current-version checks to revocation.
ClassMethod RevokeToken(id As %String) As %Status
{
    try {
        do ##class(PI.AdminSession).Require()
        set result=##class(PI.MCP.Tokens).Revoke(id,##class(PI.REST).Body())
    } catch ex { return ##class(PI.REST).RespondError(ex.Name) }
    quit ##class(PI.REST).Json(result)
}
}
