Class PI.FHIRTests Extends %RegisteredObject
{
/// Create one synthetic FHIR R4 message with an unambiguous local profile.
ClassMethod Message(bundleId As %String = "bundle-1", headerId As %String = "header-1", patientId As %String = "FHIR-PATIENT-1", source As %String = "HIS", version As %String = "1") As %DynamicObject
{
    set header={"resourceType":"MessageHeader","id":(headerId),"eventCoding":{"system":"https://example.org/fhir/CodeSystem/identity-event","code":"patient-upsert"},"source":{"endpoint":("urn:pi:source:"_source)},"focus":[{"reference":"urn:uuid:22222222-2222-4222-8222-222222222222"}]}
    set patient={"resourceType":"Patient","id":(patientId),"meta":{"versionId":(version)},"identifier":[{"system":"https://example.org/fhir/identifier/synthetic-person","value":"SYN-FHIR-1001"}],"name":[{"text":"FHIR Avery Chen"}],"gender":"female","birthDate":"1988-03-17","telecom":[{"system":"phone","value":"TEST-PHONE-FHIR"}]}
    quit {"resourceType":"Bundle","id":(bundleId),"type":"message","entry":[{"fullUrl":"urn:uuid:11111111-1111-4111-8111-111111111111","resource":(header)},{"fullUrl":"urn:uuid:22222222-2222-4222-8222-222222222222","resource":(patient)}]}
}

/// Require a controlled exception and no case or record writes for invalid messages.
ClassMethod Reject(bundle As %DynamicObject, expected As %String)
{
    set before=$get(^PIData($namespace,"seq","record")),code=""
    try { set response=##class(PI.FHIR.Message).Process(bundle) } catch ex { set code=ex.Name }
    do ##class(PI.Tests).Assert(code=expected,"expected rejection "_expected_", got "_code)
    do ##class(PI.Tests).Assert($get(^PIData($namespace,"seq","record"))=before,"rejected message must not write a record")
}

/// Check standard message response shape, original retry response, and source/version idempotency.
ClassMethod Success()
{
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.FHIR.Message||Process"),"FHIR message processor must exist")
    do ##class(PI.Tests).Reset()
    set b=..Message(),response=##class(PI.FHIR.Message).Process(b)
    do ##class(PI.Tests).Assert((response.resourceType="Bundle")&&(response.type="message"),"return a message Bundle")
    set header=response.entry.%Get(0).resource
    do ##class(PI.Tests).Assert((header.resourceType="MessageHeader")&&(header.response.identifier="header-1")&&(header.response.code="ok"),"response correlates the original header")
    do ##class(PI.Tests).Assert(response.entry.%Get(1).resource.resourceType="OperationOutcome","response includes an OperationOutcome")
    do ##class(PI.Tests).Assert(response.entry.%Get(2).resource.resourceType="Parameters","response contains structured processing result")
    set params=response.entry.%Get(2).resource.parameter
    for j=0:1:params.%Size()-1 { set param=params.%Get(j) if param.%IsDefined("valueString") { do ##class(PI.Tests).Assert(param.valueString'="","FHIR string primitives must not be empty") } }

    set again=##class(PI.FHIR.Message).Process(b)
    do ##class(PI.Tests).Assert(again.%ToJSON()=response.%ToJSON(),"same message retry returns the original response")
    do ##class(PI.Tests).Assert($get(^PIData($namespace,"seq","record"))=1,"retry does not duplicate the record")
    set r=##class(PI.Store).Record(1)
    do ##class(PI.Tests).Assert((r.sourceSystem="HIS")&&(r.sourcePatientId="FHIR-PATIENT-1")&&(r.sourceVersion=1),"source and version map deterministically")
    do ##class(PI.Tests).Assert((r.name="FHIR Avery Chen")&&(r.sex="F")&&(r.identifier="SYN-FHIR-1001"),"name gender and identifier map to current business model")
    do ##class(PI.Tests).Assert($data(^PIData($namespace,"fhirMessage","bundle-1","raw")),"original message retained with accepted envelope")
    set b=..Message("bundle-2","header-2","FHIR-PATIENT-2","EMR"),second=##class(PI.FHIR.Message).Process(b)
    set rid=$get(^PIData($namespace,"source","EMR","FHIR-PATIENT-2")),cid=$get(^PIData($namespace,"recordCase",rid))
    do ##class(PI.Tests).Assert((cid'="")&&(##class(PI.Store).Case(cid).status="PENDING_AGENT"),"FHIR messages enter the existing candidate-review workflow")
    set b=..Message("bundle-3","header-3","FHIR-PATIENT-2","EMR","2"),third=##class(PI.FHIR.Message).Process(b)
    do ##class(PI.Tests).Assert((##class(PI.Store).Case(cid).incoming.sourceVersion=2)&&(##class(PI.Store).Case(cid).id=cid),"new source version updates the same case")
    write "FHIR_SUCCESS_OK",!
}

/// Reject ambiguity and unsupported semantic mappings before any irreversible business decision.
ClassMethod Boundaries()
{
    do ##class(PI.Tests).Reset()
    set b=..Message(),b.type="collection" do ..Reject(b,"FHIR_BUNDLE_REQUIRED")
    set b=..Message(),b.entry.%Get(0).resource.resourceType="Patient" do ..Reject(b,"FHIR_HEADER_REQUIRED")
    set b=..Message(),b.entry.%Get(0).resource.source.endpoint="urn:pi:source:OTHER" do ..Reject(b,"FHIR_SOURCE_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(0).resource.source.modifierExtension=[{"url":"https://example.org/modifier","valueBoolean":true}] do ..Reject(b,"FHIR_MODIFIER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).modifierExtension=[{"url":"https://example.org/modifier","valueBoolean":true}] do ..Reject(b,"FHIR_MODIFIER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(0).resource.eventCoding.code="patient-merge" do ..Reject(b,"FHIR_EVENT_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(0).resource.focus.%Get(0).reference="urn:uuid:33333333-3333-4333-8333-333333333333" do ..Reject(b,"FHIR_FOCUS_INVALID")
    set b=..Message(),b.entry.%Get(1).resource.meta.versionId="v2" do ..Reject(b,"FHIR_VERSION_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.meta.versionId="01" do ..Reject(b,"FHIR_VERSION_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.identifier.%Get(0).system="https://another.example/id" do ..Reject(b,"FHIR_IDENTIFIER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.identifier.%Get(0).value="123456789" do ..Reject(b,"FHIR_IDENTIFIER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.gender="unknown" do ..Reject(b,"FHIR_GENDER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.birthDate="1988-03" do ..Reject(b,"FHIR_PARTIAL_BIRTH_DATE")
    set b=..Message() do b.entry.%Get(1).resource.%Set("active",0,"boolean") do ..Reject(b,"FHIR_PATIENT_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.link=[{"other":{"reference":"Patient/elsewhere"},"type":"replaced-by"}] do ..Reject(b,"FHIR_PATIENT_UNSUPPORTED")
    set b=..Message() do b.entry.%Get(1).resource.identifier.%Push({"system":"https://example.org/fhir/identifier/synthetic-person","value":"SYN-FHIR-OTHER"}) do ..Reject(b,"FHIR_IDENTIFIER_AMBIGUOUS")
    set b=..Message(),b.entry.%Get(1).fullUrl=b.entry.%Get(0).fullUrl do ..Reject(b,"FHIR_DUPLICATE_FULLURL")
    set b=..Message(),b.entry.%Get(1).fullUrl="urn:uuid:not-a-uuid",b.entry.%Get(0).resource.focus.%Get(0).reference="urn:uuid:not-a-uuid" do ..Reject(b,"FHIR_FULLURL_INVALID")
    set b=..Message(),b.entry.%Get(1).resource.identifier.%Get(0).use="old" do ..Reject(b,"FHIR_IDENTIFIER_UNSUPPORTED")
    set b=..Message(),b.entry.%Get(1).resource.identifier.%Get(0).period={"end":"2001-01-01"} do ..Reject(b,"FHIR_IDENTIFIER_UNSUPPORTED")

    set b=..Message(),b.entry.%Get(1).resource.name=[{"text":"A"},{"text":"B"}] do ..Reject(b,"FHIR_NAME_AMBIGUOUS")
    set b=..Message(),b.entry.%Get(1).resource="not an object" do ..Reject(b,"FHIR_INVALID_STRUCTURE")
    set b=..Message(),saved=##class(PI.FHIR.Message).Process(b)
    set changed=..Message(),changed.entry.%Get(1).resource.name.%Get(0).text="Changed Name" do ..Reject(changed,"FHIR_MESSAGE_ID_CONFLICT")
    set changed=..Message("bundle-1","header-other") do ..Reject(changed,"FHIR_MESSAGE_ID_CONFLICT")
    set changed=..Message("bundle-other","header-1") do ..Reject(changed,"FHIR_MESSAGE_ID_CONFLICT")
    set changed=..Message("bundle-old","header-old","FHIR-PATIENT-1","HIS","2"),saved=##class(PI.FHIR.Message).Process(changed)
    set older=..Message("bundle-older","header-older","FHIR-PATIENT-1","HIS","1"),older.entry.%Get(1).resource.name.%Get(0).text="Modified" do ..Reject(older,"VERSION_CONFLICT")
    write "FHIR_BOUNDARIES_OK",!
}
/// Simultaneous retries share one atomic response and one persisted source record.
ClassMethod Concurrent()
{
    do ##class(PI.Tests).Reset()
    kill ^PIFHIRTest($namespace)
    set b=..Message(),^PIFHIRTest($namespace,"raw")=b.%ToJSON()
    job ..ConcurrentWorker(1,0) set p1=$zchild
    job ..ConcurrentWorker(2,0) set p2=$zchild
    set start=$zh
    for { quit:$data(^PIFHIRTest($namespace,"result",1))&&$data(^PIFHIRTest($namespace,"result",2))  quit:($zh-start)>10  hang 0.02 }
    if '$data(^PIFHIRTest($namespace,"result",1)) { do $system.Process.Terminate(p1) }
    if '$data(^PIFHIRTest($namespace,"result",2)) { do $system.Process.Terminate(p2) }
    do ##class(PI.Tests).Assert($get(^PIFHIRTest($namespace,"result",1))="OK", "first concurrent message succeeds")
    do ##class(PI.Tests).Assert($get(^PIFHIRTest($namespace,"result",2))="OK", "second concurrent retry succeeds")
    do ##class(PI.Tests).Assert($get(^PIFHIRTest($namespace,"response",1))=$get(^PIFHIRTest($namespace,"response",2)),"concurrent retry returns the same saved response")
    do ##class(PI.Tests).Assert($get(^PIData($namespace,"seq","record"))=1,"concurrent retry creates one record")
    do ##class(PI.Tests).Reset()
    kill ^PIFHIRTest($namespace,"result"),^PIFHIRTest($namespace,"response")
    job ..ConcurrentWorker(1,0) set p1=$zchild
    job ..ConcurrentWorker(2,1) set p2=$zchild
    set start=$zh
    for { quit:$data(^PIFHIRTest($namespace,"result",1))&&$data(^PIFHIRTest($namespace,"result",2))  quit:($zh-start)>10  hang 0.02 }
    if '$data(^PIFHIRTest($namespace,"result",1)) { do $system.Process.Terminate(p1) }
    if '$data(^PIFHIRTest($namespace,"result",2)) { do $system.Process.Terminate(p2) }
    set a=$get(^PIFHIRTest($namespace,"result",1)),b=$get(^PIFHIRTest($namespace,"result",2))
    do ##class(PI.Tests).Assert(((a="OK")&&(b="FHIR_MESSAGE_ID_CONFLICT"))||((b="OK")&&(a="FHIR_MESSAGE_ID_CONFLICT")),"conflicting messages cannot reuse one envelope")
    do ##class(PI.Tests).Assert($get(^PIData($namespace,"seq","record"))=1,"conflicting concurrent messages create at most one record")
    kill ^PIFHIRTest($namespace)
    write "FHIR_CONCURRENT_OK",!
}

/// Run actual transactional ingestion from independent IRIS jobs without a model or remote call.
ClassMethod ConcurrentWorker(id As %Integer, changed As %Boolean)
{
    set bundle={}.%FromJSON(^PIFHIRTest($namespace,"raw"))
    if changed { set bundle.entry.%Get(1).resource.name.%Get(0).text="Another Synthetic Name" }
    try { set response=##class(PI.FHIR.Message).Process(bundle),^PIFHIRTest($namespace,"response",id)=response.%ToJSON(),^PIFHIRTest($namespace,"result",id)="OK" } catch ex { set ^PIFHIRTest($namespace,"result",id)=ex.Name }
}
}
