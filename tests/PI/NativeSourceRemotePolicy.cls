Class PI.NativeSourceRemotePolicy Extends %AI.Policy.Authorization
{
/// Allow only the isolated gateway and its three native source tools during tests.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        set name=call.%Get("name","")
        if '$listfind($listfromstring("mcp_native-source-test_verify_source_record,mcp_native-source-test_request_enrichment,mcp_native-source-test_get_enrichment"),name) { throw ##class(%Exception.General).%New("DENIED") }
        if $extract(toolref,1,11)'="mcp:remote:" { throw ##class(%Exception.General).%New("DENIED") }
        set refs=[].%FromJSON($extract(toolref,12,*)),ref=refs.%Get(0)
        if (refs.%Size()'=1)!(ref.url'="http://127.0.0.1:52788/mcp")!(ref.auth.type'="bearer") { throw ##class(%Exception.General).%New("DENIED") }
        if ref.auth.token'=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.Source") { throw ##class(%Exception.General).%New("DENIED") }
        return 1
    } catch ex { return $system.Status.Error(5001,"TEST_ENDPOINT_DENIED") }
}
}
