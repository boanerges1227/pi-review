Class PI.NativeSourceTests Extends %RegisteredObject
{
/// Create a signed capability credential used only in isolated tests.
ClassMethod Capability(action As %String, caseId As %String = "c1", requestId As %String = "", version As %Integer = 1, expiryDelta As %Integer = 60) As %String
{
    if requestId="" { set requestId=$get(^PISourceTest($job,"requestId")) }
    set now=$ztimestamp,epoch=(($piece(now,",",1)-47117)*86400)+$piece(now,",",2)
    set scope={"namespace":"PITEST","caseId":(caseId),"caseVersion":1,"runId":7,"sourceSystem":"CHECKUP","sourcePatientId":"MCP-CHECKUP-A","sourceVersion":(version),"action":(action),"expires":(epoch+expiryDelta),"requestId":(requestId),"missingFields":["identifier"]}
    set payload=$translate($system.Encryption.Base64Encode(scope.%ToJSON()),"+/="_$char(13,10),"-_"),hash=$system.Encryption.HMACSHA(256,payload,"synthetic-test-secret"),hex=""
    for i=1:1:$length(hash) { set part=$zhex($ascii(hash,i)),hex=hex_$select($length(part)=1:"0",1:"")_part }
    quit payload_"."_$zconvert(hex,"L")
}

/// Verify signatures, historical versions, idempotent receipts, and scope binding.
ClassMethod Run()
{
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.MCP.NativeSource||Call"),"native source must exist")
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set ^PISourceTest($job,"requestId")="native-test-"_$translate($system.Util.CreateGUID(),"{}-")
    set v=##class(PI.MCP.NativeSource).Call("verify_source_record",..Capability("verify_source_record"),"synthetic-test-secret")
    do ##class(PI.Tests).Assert((v.status="VERIFIED")&&(v.record.identifier="")&&(v.latestVersion=2),"historical version retained")
    set a=##class(PI.MCP.NativeSource).Call("request_enrichment",..Capability("request_enrichment"),"synthetic-test-secret"),b=##class(PI.MCP.NativeSource).Call("request_enrichment",..Capability("request_enrichment"),"synthetic-test-secret")
    do ##class(PI.Tests).Assert(a.receiptId=b.receiptId,"duplicate has same durable receipt")
    set c=##class(PI.MCP.NativeSource).Call("get_enrichment",..Capability("get_enrichment"),"synthetic-test-secret")
    do ##class(PI.Tests).Assert((c.status="READY")&&(c.record.sourceVersion=2)&&(c.record.identifier="SYN-MCP-1001"),"enrichment returns later source")
    set denied=0 try { set x=##class(PI.MCP.NativeSource).Call("get_enrichment",..Capability("get_enrichment","c2"),"synthetic-test-secret") } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"request cannot be rebound")
    set denied=0 try { set x=##class(PI.MCP.NativeSource).Call("verify_source_record",..Capability("verify_source_record","c1","t",1,-1),"synthetic-test-secret") } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"expired scope denied")
    set denied=0 try { set x=##class(PI.MCP.NativeSource).Call("verify_source_record",..Capability("verify_source_record")_"0","synthetic-test-secret") } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"forged signature denied")
    kill ^PISourceData($namespace,"request",^PISourceTest($job,"requestId")),^PISourceTest($job)
    write "NATIVE_SOURCE_TESTS_OK",!
}

/// Save one receipt for concurrent requests for the same task and reject conflicting bindings.
ClassMethod Concurrent()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set id="native-race-"_$translate($system.Util.CreateGUID(),"{}-"),^PISourceRace($namespace,id,"go")=0
    job ..Worker(id,"c1",1)
    job ..Worker(id,"c1",2)
    set ^PISourceRace($namespace,id,"go")=1,start=$zh
    for { quit:$data(^PISourceRace($namespace,id,"result",1))&&$data(^PISourceRace($namespace,id,"result",2))  quit:($zh-start)>10  hang 0.01 }
    set a=$get(^PISourceRace($namespace,id,"result",1)),b=$get(^PISourceRace($namespace,id,"result",2))
    do ##class(PI.Tests).Assert((a'="")&&(a=b),"concurrent duplicate returns one receipt")
    kill ^PISourceData($namespace,"request",id),^PISourceRace($namespace,id)
    set id="native-race-"_$translate($system.Util.CreateGUID(),"{}-"),^PISourceRace($namespace,id,"go")=0
    job ..Worker(id,"c1",1)
    job ..Worker(id,"c2",2)
    set ^PISourceRace($namespace,id,"go")=1,start=$zh
    for { quit:$data(^PISourceRace($namespace,id,"result",1))&&$data(^PISourceRace($namespace,id,"result",2))  quit:($zh-start)>10  hang 0.01 }
    set a=$get(^PISourceRace($namespace,id,"result",1)),b=$get(^PISourceRace($namespace,id,"result",2))
    do ##class(PI.Tests).Assert(((a="DENIED")&&(b'="")&&(b'="DENIED"))!((b="DENIED")&&(a'="")&&(a'="DENIED")),"concurrent conflicting binding rejected")
    kill ^PISourceData($namespace,"request",id),^PISourceRace($namespace,id)
    write "NATIVE_SOURCE_CONCURRENCY_OK",!
}

/// Simulate concurrent creation requests in a separate job.
ClassMethod Worker(id As %String, caseId As %String, index As %Integer)
{
    set start=$zh
    for { quit:$get(^PISourceRace($namespace,id,"go"))  quit:($zh-start)>5  hang 0.01 }
    try { set response=##class(PI.MCP.NativeSource).Call("request_enrichment",..Capability("request_enrichment",caseId,id),"synthetic-test-secret"),result=response.receiptId } catch ex { set result="DENIED" }
    set ^PISourceRace($namespace,id,"result",index)=result
}







/// Verify gateway configuration is generated privately without exposing credentials or overwriting files.
ClassMethod GatewayConfig()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set dir="/tmp/pi-native-test-"_$translate($system.Util.CreateGUID(),"{}-"),test={"password":"SyntheticPassword1234567890"}
    do ##class(PI.MCP.NativeSetup).GatewayFiles(dir,test)
    do ##class(PI.Tests).Assert(##class(%File).Exists(dir_"/source-shared.toml"),"shared gateway config created")
    do ##class(PI.Tests).Assert((##class(%File).Attributes(dir)#512)=448,"gateway directory private")
    do ##class(PI.Tests).Assert((##class(%File).Attributes(dir_"/source-shared.toml")#512)=384,"gateway file private")
    do ##class(PI.MCP.NativeSetup).GatewayFiles(dir,test)
    do ##class(%File).Delete(dir_"/source-shared.toml") do ##class(%File).RemoveDirectory(dir)
    write "NATIVE_GATEWAY_CONFIG_OK",!
}


/// Verify maintenance mode waits for active calls and rejects subsequent source requests.
ClassMethod Gate()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    if $data(^PISourceData($namespace,"maintenance")) { throw ##class(%Exception.General).%New("TEST_GATE_CONFLICT") }
    set id="gate-"_$translate($system.Util.CreateGUID(),"{}-"),^PISourceGateTest($namespace,id,"active")=0
    job ..GateWorker(id)
    set start=$zh
    for { quit:$get(^PISourceGateTest($namespace,id,"active"))  quit:($zh-start)>5  hang .01 }
    do ##class(PI.Tests).Assert($get(^PISourceGateTest($namespace,id,"active")),"worker entered source call")
    do ##class(PI.MCP.SourceGate).EnterMaintenance(id,10)
    try {
        do ##class(PI.Tests).Assert($get(^PISourceGateTest($namespace,id,"done")),"maintenance waits for in-flight call")
        set denied=0 try { do ##class(PI.MCP.SourceGate).Begin(1) } catch ex { set denied=(ex.Name="SOURCE_MAINTENANCE") }
        do ##class(PI.Tests).Assert(denied,"new calls blocked during maintenance")
        set denied=0 try { do ##class(PI.MCP.SourceGate).BeginInbound(1) } catch ex { set denied=(ex.Name="SOURCE_MAINTENANCE") }
        do ##class(PI.Tests).Assert(denied,"direct inbound calls blocked during maintenance")
        set denied=0 try { do ##class(PI.MCP.SourceGate).LeaveMaintenance("wrong") } catch ex { set denied=1 }
        do ##class(PI.Tests).Assert(denied,"other operation cannot clear maintenance")
    } catch ex { do ##class(PI.MCP.SourceGate).LeaveMaintenance(id) kill ^PISourceGateTest($namespace,id) throw ex }
    do ##class(PI.MCP.SourceGate).LeaveMaintenance(id)
    do ##class(PI.MCP.SourceGate).Begin(1) do ##class(PI.MCP.SourceGate).End()
    kill ^PISourceGateTest($namespace,id)
    write "NATIVE_SOURCE_GATE_OK",!
}

/// Hold the gate in a separate job to simulate an in-flight source call.
ClassMethod GateWorker(id As %String)
{
    do ##class(PI.MCP.SourceGate).Begin(5)
    set ^PISourceGateTest($namespace,id,"active")=1
    hang 1
    set ^PISourceGateTest($namespace,id,"done")=1
    do ##class(PI.MCP.SourceGate).End()
}

/// Verify maintenance mode also waits for direct calls already admitted by the native endpoint.
ClassMethod InboundDrain()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set id="inbound-"_$translate($system.Util.CreateGUID(),"{}-"),^PISourceGateTest($namespace,id,"active")=0
    job ..InboundWorker(id)
    set start=$zh
    for { quit:$get(^PISourceGateTest($namespace,id,"active"))  quit:($zh-start)>5  hang .01 }
    do ##class(PI.Tests).Assert($get(^PISourceGateTest($namespace,id,"active")),"inbound worker entered")
    do ##class(PI.MCP.SourceGate).EnterMaintenance(id,10)
    try { do ##class(PI.Tests).Assert($get(^PISourceGateTest($namespace,id,"done")),"maintenance drains inbound calls") } catch ex { do ##class(PI.MCP.SourceGate).LeaveMaintenance(id) throw ex }
    do ##class(PI.MCP.SourceGate).LeaveMaintenance(id)
    kill ^PISourceGateTest($namespace,id)
    write "NATIVE_INBOUND_DRAIN_OK",!
}

/// Simulate a direct request already admitted to the native source service.
ClassMethod InboundWorker(id As %String)
{
    do ##class(PI.MCP.SourceGate).BeginInbound(5)
    set ^PISourceGateTest($namespace,id,"active")=1
    hang 1
    set ^PISourceGateTest($namespace,id,"done")=1
    do ##class(PI.MCP.SourceGate).EndInbound()
}


/// Verify private file creation and permissions and ensure repeated initialization preserves existing content.
ClassMethod PrivateFile()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set dir="/tmp/pi-bootstrap-test-"_$translate($system.Util.CreateGUID(),"{}-"),path=dir_"/fixture"
    do ##class(PI.MCP.NativeBootstrap).PrivateDirectory(dir)
    do ##class(PI.MCP.NativeBootstrap).WriteNew(path,"synthetic-value")
    do ##class(PI.Tests).Assert((##class(%File).Attributes(dir)#512)=448,"bootstrap directory private")
    do ##class(PI.Tests).Assert((##class(%File).Attributes(path)#512)=384,"bootstrap file private")
    set denied=0 try { do ##class(PI.MCP.NativeBootstrap).WriteNew(path,"replacement") } catch ex { set denied=1 }
    do ##class(PI.Tests).Assert(denied,"bootstrap refuses to replace credentials")
    set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile(path)
    do ##class(PI.Tests).Assert(stream.Read(100)="synthetic-value","existing private file retained")
    do ##class(%File).Delete(path) do ##class(%File).RemoveDirectory(dir)
    write "NATIVE_PRIVATE_FILE_OK",!
}






/// Verify both namespace endpoints are served by one private source gateway configuration.
ClassMethod SharedGatewayConfig()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    set dir="/tmp/pi-shared-gateway-test-"_$translate($system.Util.CreateGUID(),"{}-"),p=dir_"/source-shared.toml",c={"password":"SyntheticPassword1234567890"}
    do ##class(PI.MCP.NativeSetup).GatewayFiles(dir,c)
    do ##class(PI.Tests).Assert(##class(%File).Exists(p),"one shared source gateway configuration")
    set f=##class(%Stream.FileCharacter).%New(),sc=f.LinkToFile(p),text=f.Read(8192)
    do ##class(PI.Tests).Assert(($find(text,"path=""/mcp/native-source""")>0)&&($find(text,"path=""/mcp/native-source-test""")>0),"shared gateway contains both source endpoints")
    do ##class(PI.Tests).Assert((##class(%File).Attributes(p)#512)=384,"shared config private")
    do ##class(%File).Delete(p) do ##class(%File).RemoveDirectory(dir)
    write "SHARED_SOURCE_GATEWAY_CONFIG_OK",!
}

}
