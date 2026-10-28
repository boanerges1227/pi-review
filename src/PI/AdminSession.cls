Class PI.AdminSession Extends %RegisteredObject
{
/// Check the idle deadline using server-side UTC seconds, independent of browser time and session cleanup.
ClassMethod Now() As %Numeric
{
    set stamp=$ztimestamp
    quit (($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
}

/// Accept only sessions created by this site's login endpoint; cached Basic credentials cannot bypass login or logout.
ClassMethod Current() As %DynamicObject
{
    if '$data(%session) { quit {"authenticated":false} }
    if '$isobject(%session) { quit {"authenticated":false} }
    if $get(%session.Data("PIAdminApp"))'=%request.Application { quit {"authenticated":false} }
    if ($get(%session.Data("PIAdminUser"))="")!($get(%session.Data("PIAdminUser"))'=$username) { quit {"authenticated":false} }
    if ..Now()>=+$get(%session.Data("PIAdminDeadline")) { do ..End() quit {"authenticated":false} }
    try { do ##class(PI.ModelSettings).RequireAdmin() } catch ex { return {"authenticated":false} }
    set %session.Data("PIAdminDeadline")=..Now()+%session.Data("PIAdminTimeout")
    quit {"authenticated":true,"username":($username),"idleTimeoutSeconds":(%session.Data("PIAdminTimeout"))}
}

/// Check the native session and current admin permissions for every admin endpoint; anonymous requests receive JSON 401 without a Basic prompt.
ClassMethod Require()
{
    set state=..Current()
    if 'state.authenticated { do ..End() throw ##class(%Exception.General).%New("ADMIN_AUTHENTICATION_REQUIRED") }
    do ##class(PI.ModelSettings).RequireAdmin()
}

/// Authenticate with native IRIS credentials without logging request bodies, passwords, or authentication details.
ClassMethod Login(data As %DynamicObject) As %DynamicObject
{
    // Allow login only in a newly created IRIS session; the client ends the old anonymous session before submitting credentials once.
    // Avoid private native methods and prevent a known anonymous cookie from being elevated to an admin session.
    if '%session.NewSession { do ..End() throw ##class(%Exception.General).%New("ADMIN_NEW_SESSION_REQUIRED") }
    if (data.%GetTypeOf("username")'="string")!(data.%GetTypeOf("password")'="string") { throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED") }
    set username=data.username,password=data.password
    if ($length(username)<1)!($length(username)>128)!($length(password)<1)!($length(password)>2048) { throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED") }
    set %session.Data("PIAdminUser")="",%session.Data("PIAdminApp")=""
    set timeout=%session.AppTimeout
    set sc=%session.Logout(1)
    try { set sc=%session.Login(username,password,0,,.appError) } catch ex { set sc=0 }
    set password="",data.password=""
    if (sc'=1)!($system.Status.IsError($get(appError,1))) {
        do ..End()
        throw ##class(%Exception.General).%New("ADMIN_LOGIN_FAILED")
    }
    try { do ##class(PI.ModelSettings).RequireAdmin() } catch ex {
        do ..End()
        throw ##class(%Exception.General).%New("ADMIN_PERMISSION_REQUIRED")
    }
    set %session.Data("PIAdminUser")=$username,%session.Data("PIAdminApp")=%request.Application
    set %session.AppTimeout=$select((timeout>0)&&(timeout<=1800):timeout,1:1800)
    set %session.Data("PIAdminTimeout")=%session.AppTimeout,%session.Data("PIAdminDeadline")=..Now()+%session.AppTimeout
    quit ..Current()
}

/// Log out the native identity and end the session so old cookies cannot access admin data.
ClassMethod End()
{
    set %session.Data("PIAdminUser")="",%session.Data("PIAdminApp")=""
    set %session.Data("PIAdminDeadline")=0
    set sc=%session.Logout(1)
    set %session.EndSession=1
}

/// Idempotent logout does not require current admin privileges, but the caller must first verify the same-origin boundary.
ClassMethod Logout() As %DynamicObject
{
    do ..End()
    quit {"authenticated":false}
}
}
