Class PI.NativeSourceRemote Extends %AI.ToolSet
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="NativeSourceRemoteTest"><MCP Name="Source"><Remote URL="http://127.0.0.1:52788/mcp" AuthType="bearer" Token="@{wallet:PIMCP.Source}"/></MCP></ToolSet>
}

/// Exercise native MCP tools over the network through the isolated gateway.
ClassMethod Run()
{
    set secret=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.NativeTestSigning"),stamp=$ztimestamp,epoch=(($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
    set scope={"namespace":"PITEST","caseId":"c1","caseVersion":1,"runId":7,"sourceSystem":"CHECKUP","sourcePatientId":"MCP-CHECKUP-A","sourceVersion":1,"action":"verify_source_record","expires":(epoch+60)}
    set payload=$translate($system.Encryption.Base64Encode(scope.%ToJSON()),"+/="_$char(13,10),"-_"),hash=$system.Encryption.HMACSHA(256,payload,secret),hex=""
    for i=1:1:$length(hash) { set part=$zhex($ascii(hash,i)),hex=hex_$select($length(part)=1:"0",1:"")_part }
    do ##class(%AI.Utils.SettingStore).RegisterDefaults()
    set manager=##class(%AI.ToolMgr).%New(),manifest=..%New().%Discover(),spec=##class(%AI.Utils.SettingStore).Expand(manifest.tools.%Get(0).toolref),sc=manager.AddTool(spec)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("NATIVE_REMOTE_ADD_FAILED") }
    set sc=manager.SetAuthPolicy(##class(PI.NativeSourceRemotePolicy).%New())
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("TEST_POLICY_FAILED") }
    set tools=manager.%Discover()
    write "DISCOVERY_CLASS=",$classname(tools),!
    for i=0:1:tools.%Size()-1 { write "DISCOVERED_NAME=",tools.%Get(i).%Get("name",""),! }
    set response=manager.ExecuteTool("mcp_native-source-test_verify_source_record",{"capability":(payload_"."_$zconvert(hex,"L"))})
    if '$isobject(response) { throw ##class(%Exception.General).%New("NATIVE_REMOTE_INVALID") }
    set value=response.%Get("value",{})
    do ##class(PI.Tests).Assert((value.%Get("status","")="VERIFIED")&&(value.%Get("sourceVersion",0)=1),"native remote source verification")
    set denied=0
    try { set invalid=manager.ExecuteTool("mcp_native-source-test_verify_source_record",{"capability":(payload_"."_$zconvert(hex,"L")_"0")}) } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"forged capability rejected over native MCP")
    set bearerSecret=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.Source"),hash=$system.Encryption.HMACSHA(256,payload,bearerSecret),forged=""
    for i=1:1:$length(hash) { set part=$zhex($ascii(hash,i)),forged=forged_$select($length(part)=1:"0",1:"")_part }
    set denied=0
    try { set invalid=manager.ExecuteTool("mcp_native-source-test_verify_source_record",{"capability":(payload_"."_$zconvert(forged,"L"))}) } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"bearer token cannot sign capability")
    // The shared bearer credential cannot make a USER signing key valid for PITEST.
    set userSecret=##class(%Wallet.KeyValue).GetSecretValue("PIMCP.SourceSigning")
    do ##class(PI.Tests).Assert((userSecret'="")&&(secret'="")&&(userSecret'=secret),"namespace signing keys are populated and distinct")
    set hash=$system.Encryption.HMACSHA(256,payload,userSecret),forged=""
    for i=1:1:$length(hash) { set part=$zhex($ascii(hash,i)),forged=forged_$select($length(part)=1:"0",1:"")_part }
    set denied=0
    try { set invalid=manager.ExecuteTool("mcp_native-source-test_verify_source_record",{"capability":(payload_"."_$zconvert(forged,"L"))}) } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"USER signing key cannot authorize PITEST source")
    write "NATIVE_MCP_NETWORK_OK",!
}
}
