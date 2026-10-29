Class PI.ProductionPortal Extends %RegisteredObject
{
/// Read fixed demo credentials only after authenticating the existing site administrator session.
ClassMethod Target() As %DynamicObject
{
    do ##class(PI.AdminSession).Require()
    try {
        set path=$system.Util.GetEnviron("PI_PRODUCTION_CREDENTIALS_FILE")
        if path="" { set path="/durable/iris/private/production-login-"_$namespace_".json" }
        set stream=##class(%Stream.FileCharacter).%New(),stream.TranslateTable="UTF8"
        set sc=stream.LinkToFile(path)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("INVALID_CONFIG") }
        if (stream.Size=0)!(stream.Size>8192) { throw ##class(%Exception.General).%New("INVALID_CONFIG") }
        set config={}.%FromJSON(stream)
        if 'config.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("INVALID_CONFIG") }
        if (config.%GetTypeOf("username")'="string")!(config.%GetTypeOf("password")'="string") { throw ##class(%Exception.General).%New("INVALID_CONFIG") }
        set username=config.username,password=config.password
        if ($length(username)<1)!($length(username)>128)!($length(password)<1)!($length(password)>2048) { throw ##class(%Exception.General).%New("INVALID_CONFIG") }
    } catch ex { throw ##class(%Exception.General).%New("PRODUCTION_PORTAL_NOT_CONFIGURED") }
    // The destination and namespace come from server configuration, never browser query parameters.
    set url="/csp/"_$zconvert($namespace,"L")_"/EnsPortal.ProductionConfig.zen?$NAMESPACE="_$zconvert($namespace,"O","URL")_"&PRODUCTION=PI.Production"
    // Convert Unicode to UTF-8 bytes before URL encoding; IRIS otherwise emits nonstandard %uXXXX escapes.
    set url=url_"&IRISUsername="_$zconvert($zconvert(username,"O","UTF8"),"O","URL")_"&IRISPassword="_$zconvert($zconvert(password,"O","UTF8"),"O","URL")
    quit {"url":(url),"namespace":($namespace),"production":"PI.Production","username":(username)}
}
}
