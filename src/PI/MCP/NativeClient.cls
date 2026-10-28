Class PI.MCP.NativeClient Extends %RegisteredObject
{
/// Sign the current case and source version and call source tools through the native MCP gateway.
ClassMethod Call(c As %DynamicObject, record As %DynamicObject, action As %String, task As %DynamicObject = "") As %DynamicObject
{
    set start=$zh,callId=$increment(^PIData($namespace,"seq","mcp")),run=$get(^PIData($namespace,"context",$job,"runId")),outcome="FAILED"
    try {
        if '$listfind($listfromstring("verify_source_record,request_enrichment,get_enrichment"),action) { throw ##class(%Exception.General).%New("SOURCE_TOOL_DENIED") }
        set now=$ztimestamp,expires=(($piece(now,",",1)-47117)*86400)+$piece(now,",",2)+60
        set scope={"namespace":($namespace),"caseId":(c.id),"caseVersion":(c.version),"runId":(run),"sourceSystem":(record.sourceSystem),"sourcePatientId":(record.sourcePatientId),"sourceVersion":(record.sourceVersion),"action":(action),"expires":(expires)}
        if $isobject(task) { set scope.requestId=task.requestId,scope.missingFields=task.missingFields,scope.caseVersion=task.waitingVersion }
        set payload=$translate($system.Encryption.Base64Encode(scope.%ToJSON()),"+/="_$char(13,10),"-_")
        set signing=$select($namespace="PITEST":"PIMCP.NativeTestSigning",$namespace="USER":"PIMCP.SourceSigning",1:"")
        if signing="" { throw ##class(%Exception.General).%New("SOURCE_NAMESPACE_DENIED") }
        set secret=##class(%Wallet.KeyValue).GetSecretValue(signing),hash=$system.Encryption.HMACSHA(256,payload,secret),hex=""
        for i=1:1:$length(hash) { set part=$zhex($ascii(hash,i)),hex=hex_$select($length(part)=1:"0",1:"")_part }
        do ##class(%AI.Utils.SettingStore).RegisterDefaults()
        set manager=##class(%AI.ToolMgr).%New()
        set classname=$select($namespace="PITEST":"PI.MCP.NativeSourceRemotePITEST",1:"PI.MCP.NativeSourceRemoteUSER"),manifest=$classmethod(classname,"%New").%Discover()
        set spec=##class(%AI.Utils.SettingStore).Expand(manifest.tools.%Get(0).toolref)
        set sc=manager.AddTool(spec)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SOURCE_CONNECT_FAILED") }
        set sc=manager.SetAuthPolicy(##class(PI.MCP.NativeRemotePolicy).%New())
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SOURCE_POLICY_FAILED") }
        set tools=manager.%Discover()
        set prefix=$select($namespace="PITEST":"mcp_native-source-test_",1:"mcp_native-source_")
        set response=manager.ExecuteTool(prefix_action,{"capability":(payload_"."_$zconvert(hex,"L"))})
        if '$isobject(response) { throw ##class(%Exception.General).%New("SOURCE_INVALID_RESPONSE") }
        set data=response.%Get("value",{})
        if $length(data.%ToJSON())>12000 { throw ##class(%Exception.General).%New("SOURCE_RESPONSE_TOO_LARGE") }
        for key="namespace","caseId","caseVersion","runId","sourceSystem","sourcePatientId","sourceVersion" {
            if data.%Get(key,"")'=scope.%Get(key,"") { throw ##class(%Exception.General).%New("SOURCE_SCOPE_MISMATCH") }
        }
        if (data.%Get("transport","")'="mcp")!(data.%Get("receiptId","")="") { throw ##class(%Exception.General).%New("SOURCE_INVALID_RECEIPT") }
        if $isobject(task),data.%Get("requestId","")'=task.requestId { throw ##class(%Exception.General).%New("SOURCE_REQUEST_MISMATCH") }
        set outcome="OK",^PIData($namespace,"mcpHealth")={"lastCall":($zdatetime($horolog,3)),"status":"OK","server":"synthetic-source"}.%ToJSON()
    } catch ex {
        set ^PIData($namespace,"mcpHealth")={"lastCall":($zdatetime($horolog,3)),"status":"UNAVAILABLE","server":"synthetic-source"}.%ToJSON()
        do ..Trace(c,run,callId,action,outcome,$zh-start)
        throw ##class(%Exception.General).%New("SOURCE_MCP_UNAVAILABLE")
    }
    do ..Trace(c,run,callId,action,outcome,$zh-start)
    quit data
}

/// Record correlation audit data without credentials or raw responses.
ClassMethod Trace(c As %DynamicObject, run As %Integer, callId As %Integer, action As %String, outcome As %String, seconds As %Numeric)
{
    set stamp=$ztimestamp,epoch=(($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
    set ^PIData($namespace,"mcpTrace",c.id,callId)={"callId":(callId),"occurredAtEpoch":(epoch),"caseId":(c.id),"caseVersion":(c.version),"runId":(run),"server":"synthetic-source","transport":"mcp","tool":(action),"outcome":(outcome),"elapsedSeconds":(seconds)}.%ToJSON()
}
}
