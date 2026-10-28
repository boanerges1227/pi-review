Class PI.MCP.NativeSource Extends %RegisteredObject
{
/// Validate the signed scope and process synthetic source requests without letting callers choose the server key.
ClassMethod Call(action As %String, capability As %String, secret As %String) As %DynamicObject
{
    do ##class(PI.MCP.SourceGate).BeginInbound()
    try { set result=..CallProtected(action,capability,secret) } catch ex { do ##class(PI.MCP.SourceGate).EndInbound() throw ex }
    do ##class(PI.MCP.SourceGate).EndInbound()
    quit result
}

/// Validate the access scope and execute the source operation under the ingress lock.
ClassMethod CallProtected(action As %String, capability As %String, secret As %String) As %DynamicObject
{
    if '$listfind($listfromstring("verify_source_record,request_enrichment,get_enrichment"),action) { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
    if ($length(secret)<16)!($length(capability)>8192)!($length($piece(capability,".",2))'=64)!($length($piece(capability,".",3))>0) { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
    set payload=$piece(capability,".",1),supplied=$piece(capability,".",2),digest=$system.Encryption.HMACSHA(256,payload,secret),expected=""
    for i=1:1:$length(digest) { set part=$zhex($ascii(digest,i)),expected=expected_$select($length(part)=1:"0",1:"")_part }
    set expected=$zconvert(expected,"L"),difference=0
    for i=1:1:64 { set difference=difference+($ascii(expected,i)'=$ascii(supplied,i)) }
    if difference { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
    try {
        set encoded=$translate(payload,"-_","+/"),encoded=encoded_$extract("===",1,(4-($length(encoded)#4))#4),scope={}.%FromJSON($system.Encryption.Base64Decode(encoded))
        set stamp=$ztimestamp,epoch=(($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
        if (scope.action'=action)!(scope.namespace'=$namespace)!(scope.expires'>epoch)!(scope.expires>(epoch+180))!(scope.caseId="")!(scope.caseVersion<1)!(scope.sourceVersion<1) { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
        set system=scope.sourceSystem,patient=scope.sourcePatientId,version=scope.sourceVersion
        if (system="")!(patient="") { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
        set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile(##class(PI.InstallPaths).SourceRegistryPath())
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SOURCE_REGISTRY_UNAVAILABLE") }
        set registry={}.%FromJSON(stream),versions=registry.%Get(system_":"_patient,{}),iter=versions.%GetIterator(),latest=0,next=0
        while iter.%GetNext(.key,.record) { if (+key)>latest { set latest=+key } if ((+key)>version)&&((next=0)||((+key)<next)) { set next=+key } }
        set result={"namespace":(scope.namespace),"caseId":(scope.caseId),"caseVersion":(scope.caseVersion),"runId":(scope.runId),"sourceSystem":(system),"sourcePatientId":(patient),"sourceVersion":(version),"transport":"mcp","synthetic":true,"server":"synthetic-source","receiptId":(..Receipt())}
        if action="verify_source_record" {
            set result.status=$select(versions.%IsDefined(version_""):"VERIFIED",1:"UNKNOWN"),result.latestVersion=latest
            if result.status="VERIFIED" { set result.record=versions.%Get(version_"") }
        } else {
            if (scope.requestId="")!('scope.%IsDefined("missingFields"))!(scope.%GetTypeOf("missingFields")'="array") { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
            set binding={"namespace":(scope.namespace),"caseId":(scope.caseId),"caseVersion":(scope.caseVersion),"sourceSystem":(system),"sourcePatientId":(patient),"sourceVersion":(version),"missingFields":(scope.missingFields)}.%ToJSON()
            if $tlevel { throw ##class(%Exception.General).%New("SOURCE_TRANSACTION_UNSUPPORTED") }
            lock +^PISourceData($namespace,"migration"):3
            if '$test { throw ##class(%Exception.General).%New("SOURCE_BUSY") }
            lock +^PISourceData($namespace,"request",scope.requestId):3
            if '$test { lock -^PISourceData($namespace,"migration") throw ##class(%Exception.General).%New("SOURCE_BUSY") }
            try {
                tstart
                set prior=$get(^PISourceData($namespace,"request",scope.requestId,"binding"))
                if prior="" {
                    if action'="request_enrichment" { throw ##class(%Exception.General).%New("SOURCE_REQUEST_NOT_FOUND") }
                    set ^PISourceData($namespace,"request",scope.requestId,"binding")=binding,^PISourceData($namespace,"request",scope.requestId,"receipt")=result.receiptId
                } else {
                    if prior'=binding { throw ##class(%Exception.General).%New("SOURCE_REQUEST_SCOPE_MISMATCH") }
                    set result.receiptId=^PISourceData($namespace,"request",scope.requestId,"receipt")
                }
                set seq=$increment(^PISourceData($namespace,"auditSeq")),^PISourceData($namespace,"audit",seq)={"time":(epoch),"caseId":(scope.caseId),"action":(action),"receiptId":(result.receiptId)}.%ToJSON()
                tcommit
            } catch ex { if $tlevel { trollback } lock -^PISourceData($namespace,"request",scope.requestId) lock -^PISourceData($namespace,"migration") throw ex }
            lock -^PISourceData($namespace,"request",scope.requestId)
            lock -^PISourceData($namespace,"migration")
            set result.requestId=scope.requestId,result.status=$select(next>0:"READY",1:"WAITING")
            if (action="get_enrichment")&&(next>0) { set result.record=versions.%Get(next_"") }
        }
        if action="verify_source_record" { set seq=$increment(^PISourceData($namespace,"auditSeq")),^PISourceData($namespace,"audit",seq)={"time":(epoch),"caseId":(scope.caseId),"action":(action),"receiptId":(result.receiptId)}.%ToJSON() }
    } catch ex { throw ##class(%Exception.General).%New("SOURCE_ACCESS_DENIED") }
    quit result
}

/// Generate a source receipt without patient data using secure IRIS randomness.
ClassMethod Receipt() As %String
{
    set bytes=$system.Encryption.GenCryptRand(12),result=""
    for i=1:1:$length(bytes) { set part=$zhex($ascii(bytes,i)),result=result_$select($length(part)=1:"0",1:"")_part }
    quit $zconvert(result,"L")
}
}
