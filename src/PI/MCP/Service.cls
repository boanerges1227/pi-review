Class PI.MCP.Service Extends %AI.MCP.Service
{
Parameter SPECIFICATION As STRING = "PI.MCP.ReadTools";

/// Bind custom bearer identity after native application checks; failed authentication leaves no actor.
ClassMethod OnAuthenticate(authType As %String, auth As %String, headers As %DynamicObject = "") As %Status
{
    kill ^||PIMCP
    try {
        if $zconvert(authType,"L")'="bearer" { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
        do ##class(PI.MCP.Access).Authenticate(auth)
        return 1
    } catch ex { return $system.Status.Error(5001,"MCP_UNAUTHORIZED") }
}

/// Clear custom state after ordinary REST dispatch; WebSocket calls independently recheck revocation.
ClassMethod OnPostDispatch(pUrl As %String, pMethod As %String, pSC As %Status) As %Status
{
    kill ^||PIMCP
    quit 1
}

/// Clear custom state after the native WebSocket connection closes.
Method OnPostServer() As %Status
{
    kill ^||PIMCP
    quit 1
}
}
