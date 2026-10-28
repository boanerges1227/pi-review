Class PI.MCP.NativeSourceService Extends %AI.MCP.Service
{
Parameter SPECIFICATION As STRING = "PI.MCP.NativeSourceTools";

/// Compare the source-specific token and reject native MCP requests on failure.
ClassMethod OnAuthenticate(authType As %String, auth As %String, headers As %DynamicObject = "") As %Status
{
    try {
        if $zconvert(authType,"L")'="bearer" { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
        set secret=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.Source")
        if ($length(auth)'=$length(secret))!($length(secret)<32) { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
        set difference=0
        for i=1:1:$length(secret) { set difference=difference+($ascii(auth,i)'=$ascii(secret,i)) }
        if difference { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
        return 1
    } catch ex { return $system.Status.Error(5001,"SOURCE_ACCESS_DENIED") }
}
}
