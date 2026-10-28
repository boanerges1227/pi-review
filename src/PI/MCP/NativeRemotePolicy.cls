Class PI.MCP.NativeRemotePolicy Extends %AI.Policy.Authorization
{
/// Restrict native source tools to the current namespace's local gateway and allowed tools.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        set prefix=$select($namespace="PITEST":"mcp_native-source-test_",$namespace="USER":"mcp_native-source_",1:"")
        set port=$select(($namespace="PITEST")!($namespace="USER"):52788,1:0)
        if (prefix="")!(port=0) { throw ##class(%Exception.General).%New("DENIED") }
        set name=call.%Get("name","")
        if $extract(name,1,$length(prefix))'=prefix { throw ##class(%Exception.General).%New("DENIED") }
        if '$listfind($listfromstring("verify_source_record,request_enrichment,get_enrichment"),$extract(name,$length(prefix)+1,*)) { throw ##class(%Exception.General).%New("DENIED") }
        if $extract(toolref,1,11)'="mcp:remote:" { throw ##class(%Exception.General).%New("DENIED") }
        set refs=[].%FromJSON($extract(toolref,12,*)),ref=refs.%Get(0)
        if (refs.%Size()'=1)!(ref.url'=("http://127.0.0.1:"_port_"/mcp"))!(ref.auth.type'="bearer") { throw ##class(%Exception.General).%New("DENIED") }
        if ref.auth.token'=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.Source") { throw ##class(%Exception.General).%New("DENIED") }
        return 1
    } catch ex { return $system.Status.Error(5001,"SOURCE_ENDPOINT_DENIED") }
}
}
