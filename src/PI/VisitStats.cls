Class PI.VisitStats Extends %RegisteredObject
{
/// Recognize login-page GETs from the configured public Cloudflare origin; proxy headers are not an authorization boundary.
ClassMethod IsPublic(method As %String, host As %String, scheme As %String, ray As %String, publicOrigin As %String) As %Boolean
{
    if (method'="GET")!(ray="")!(publicOrigin="") { quit 0 }
    set host=$zconvert(host,"L"),scheme=$zconvert(scheme,"L"),publicOrigin=$zconvert(publicOrigin,"L")
    if (scheme'="http")&&(scheme'="https") { quit 0 }
    if (host="localhost")!($extract(host,1,10)="localhost:")!($extract(host,1,4)="127.")!($extract(host,1,5)="[::1]") { quit 0 }
    quit publicOrigin=(scheme_"://"_host)
}

/// Atomically increment only the namespace aggregate; retain no IP address, Ray ID, or visitor profile.
ClassMethod Record(method As %String, host As %String, scheme As %String, ray As %String, publicOrigin As %String)
{
    if '..IsPublic(method,host,scheme,ray,publicOrigin) { quit }
    // Native $increment is atomic across worker processes, preventing concurrent page views from losing updates.
    set total=$increment(^PIVisitStats($namespace,"total"))
}

/// Expose only the cumulative page-view metric without changing it or revealing visitor-level data.
ClassMethod Snapshot() As %DynamicObject
{
    quit {"total":(+$get(^PIVisitStats($namespace,"total"))),"metric":"public-login-page-views"}
}
}
