Class PI.FHIR.Message Extends %RegisteredObject
{
/// Validate a supported local R4 message profile before starting any business transaction.
ClassMethod Convert(bundle As %DynamicObject) As %DynamicObject
{
    if '$isobject(bundle) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'bundle.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if (bundle.%Get("resourceType","")'="Bundle")!(bundle.%Get("type","")'="message") { throw ##class(%Exception.General).%New("FHIR_BUNDLE_REQUIRED") }
    if bundle.%IsDefined("action")!bundle.%IsDefined("caseId") { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    set bundleId=..Id(bundle,"id"),entries=..Array(bundle,"entry",1)
    if (entries.%Size()<2)!(entries.%Size()>20) { throw ##class(%Exception.General).%New("FHIR_ENTRY_COUNT") }
    set first=entries.%Get(0)
    if '$isobject(first) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    set header=..Object(first,"resource",1)
    if header.%Get("resourceType","")'="MessageHeader" { throw ##class(%Exception.General).%New("FHIR_HEADER_REQUIRED") }
    set headerId=..Id(header,"id"),event=..Object(header,"eventCoding",1),source=..Object(header,"source",1),focus=..Array(header,"focus",1)
    if header.%IsDefined("eventUri")!(header.%IsDefined("modifierExtension"))!(header.%IsDefined("response")) { throw ##class(%Exception.General).%New("FHIR_EVENT_UNSUPPORTED") }
    if (event.%Get("system","")'="https://example.org/fhir/CodeSystem/identity-event")!(event.%Get("code","")'="patient-upsert") { throw ##class(%Exception.General).%New("FHIR_EVENT_UNSUPPORTED") }
    set endpoint=..Text(source,"endpoint",1),system=$select(endpoint="urn:pi:source:HIS":"HIS",endpoint="urn:pi:source:EMR":"EMR",endpoint="urn:pi:source:CHECKUP":"CHECKUP",1:"")
    if system="" { throw ##class(%Exception.General).%New("FHIR_SOURCE_UNSUPPORTED") }
    if source.%IsDefined("modifierExtension") { throw ##class(%Exception.General).%New("FHIR_MODIFIER_UNSUPPORTED") }
    if focus.%Size()'=1 { throw ##class(%Exception.General).%New("FHIR_FOCUS_INVALID") }
    set target=focus.%Get(0)
    if '$isobject(target) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    set reference=..Text(target,"reference",1),patient="",matched=0,patients=0
    for i=0:1:entries.%Size()-1 {
        set entry=entries.%Get(i)
        if '$isobject(entry) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
        if entry.%IsDefined("modifierExtension") { throw ##class(%Exception.General).%New("FHIR_MODIFIER_UNSUPPORTED") }
        set resource=..Object(entry,"resource",1),resourceType=..Text(resource,"resourceType",1),fullUrl=..Text(entry,"fullUrl",1)
        if '..ValidFullUrl(fullUrl) { throw ##class(%Exception.General).%New("FHIR_FULLURL_INVALID") }
        if $data(seen(fullUrl)) { throw ##class(%Exception.General).%New("FHIR_DUPLICATE_FULLURL") }
        set seen(fullUrl)=1
        if entry.%IsDefined("request")!entry.%IsDefined("response")!entry.%IsDefined("search") { throw ##class(%Exception.General).%New("FHIR_ENTRY_INVALID") }
        if resourceType="Patient" { set patients=patients+1 }
        if (i>0)&&(resourceType="MessageHeader") { throw ##class(%Exception.General).%New("FHIR_HEADER_REQUIRED") }
        if fullUrl=reference { set patient=resource,matched=matched+1 }
    }
    if (patients'=1)!(matched'=1) { throw ##class(%Exception.General).%New("FHIR_FOCUS_INVALID") }
    if patient.%Get("resourceType","")'="Patient" { throw ##class(%Exception.General).%New("FHIR_FOCUS_INVALID") }
    if patient.%IsDefined("modifierExtension")!patient.%IsDefined("link") { throw ##class(%Exception.General).%New("FHIR_PATIENT_UNSUPPORTED") }
    if patient.%IsDefined("active") {
        if (patient.%GetTypeOf("active")'="boolean")!('patient.active) { throw ##class(%Exception.General).%New("FHIR_PATIENT_UNSUPPORTED") }
    }
    set patientId=..Id(patient,"id"),meta=..Object(patient,"meta",1),version=..Text(meta,"versionId",1)
    if (version'?1.N)!($extract(version)="0")!($length(version)>9) { throw ##class(%Exception.General).%New("FHIR_VERSION_UNSUPPORTED") }
    set names=..Array(patient,"name",1)
    if names.%Size()'=1 { throw ##class(%Exception.General).%New("FHIR_NAME_AMBIGUOUS") }
    set name=names.%Get(0)
    if '$isobject(name) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if name.%IsDefined("period") { throw ##class(%Exception.General).%New("FHIR_NAME_AMBIGUOUS") }
    if name.%IsDefined("use"),'$listfind($listfromstring("official,usual"),..Text(name,"use",1)) { throw ##class(%Exception.General).%New("FHIR_NAME_AMBIGUOUS") }
    set nameText=..Text(name,"text",1),gender=..Text(patient,"gender",1),sex=$select(gender="male":"M",gender="female":"F",1:"")
    if sex="" { throw ##class(%Exception.General).%New("FHIR_GENDER_UNSUPPORTED") }
    set birth=..Text(patient,"birthDate",0)
    if (birth'="")&&(birth'?4N1"-"2N1"-"2N) { throw ##class(%Exception.General).%New("FHIR_PARTIAL_BIRTH_DATE") }
    set identifiers=..Array(patient,"identifier",0),identity="",count=0
    for i=0:1:identifiers.%Size()-1 {
        set identifier=identifiers.%Get(i)
        if '$isobject(identifier) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
        if ..Text(identifier,"system",1)'="https://example.org/fhir/identifier/synthetic-person" { throw ##class(%Exception.General).%New("FHIR_IDENTIFIER_UNSUPPORTED") }
        if identifier.%IsDefined("period") { throw ##class(%Exception.General).%New("FHIR_IDENTIFIER_UNSUPPORTED") }
        if identifier.%IsDefined("use"),'$listfind($listfromstring("official,usual"),..Text(identifier,"use",1)) { throw ##class(%Exception.General).%New("FHIR_IDENTIFIER_UNSUPPORTED") }
        set count=count+1,identity=..Text(identifier,"value",1)
        if $extract(identity,1,4)'="SYN-" { throw ##class(%Exception.General).%New("FHIR_IDENTIFIER_UNSUPPORTED") }
    }
    if count>1 { throw ##class(%Exception.General).%New("FHIR_IDENTIFIER_AMBIGUOUS") }
    set contacts=..Array(patient,"telecom",0),phone="",count=0
    for i=0:1:contacts.%Size()-1 {
        set contact=contacts.%Get(i)
        if '$isobject(contact) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
        if contact.%Get("system","")="phone" {
            if contact.%IsDefined("period") { throw ##class(%Exception.General).%New("FHIR_PHONE_AMBIGUOUS") }
            if contact.%IsDefined("use"),contact.%Get("use","")="old" { throw ##class(%Exception.General).%New("FHIR_PHONE_AMBIGUOUS") }
            set count=count+1,phone=..Text(contact,"value",1)
        }
    }
    if count>1 { throw ##class(%Exception.General).%New("FHIR_PHONE_AMBIGUOUS") }
    set input={"sourceSystem":(system),"sourcePatientId":(patientId),"sourceVersion":(+version),"name":(nameText),"birthDate":(birth),"sex":(sex),"identifier":(identity),"phone":(phone),"notes":""}
    set normalized=##class(PI.Rules).Normalize(input)
    quit {"bundleId":(bundleId),"headerId":(headerId),"event":(event),"input":(normalized)}
}

/// Accept absolute URLs or canonical UUID URNs; never resolve external references.
ClassMethod ValidFullUrl(value As %String) As %Boolean
{
    if ($length(value)>500)!($find(value," ")>0)!($find(value,"/_history/")>0) { quit 0 }
    if $extract(value,1,9)="urn:uuid:" {
        set uuid=$extract(value,10,*),chars=$translate(uuid,"-")
        if ($length(uuid)'=36)!($length(chars)'=32) { return 0 }
        if ($extract(uuid,9)'="-")!($extract(uuid,14)'="-")!($extract(uuid,19)'="-")!($extract(uuid,24)'="-") { return 0 }
        quit $translate($zconvert(chars,"U"),"0123456789ABCDEF")=""
    }
    if ($extract(value,1,8)="https://")!($extract(value,1,7)="http://") { quit $piece(value,"/",3)'="" }
    quit 0
}

/// Require FHIR logical identifiers with the R4 id character set and maximum length.
ClassMethod Id(obj As %DynamicObject, key As %String) As %String
{
    set value=..Text(obj,key,1)
    if ($length(value)>64)!($translate(value,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")'="") { throw ##class(%Exception.General).%New("FHIR_ID_INVALID") }
    quit value
}

/// Require a string or return an empty optional string without coercing JSON objects or numbers.
ClassMethod Text(obj As %DynamicObject, key As %String, required As %Boolean) As %String
{
    if '$isobject(obj) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsDefined(key) { if required { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") } else { return "" } }
    if obj.%GetTypeOf(key)'="string" { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    set value=obj.%Get(key)
    if required,value="" { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    quit value
}

/// Extract an object without allowing dynamic arrays or scalar values to masquerade as resources.
ClassMethod Object(obj As %DynamicObject, key As %String, required As %Boolean) As %DynamicObject
{
    if '$isobject(obj) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsDefined(key) { if required { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") } else { return {} } }
    if obj.%GetTypeOf(key)'="object" { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    quit obj.%Get(key)
}

/// Treat an absent optional array as empty; reject non-array representations.
ClassMethod Array(obj As %DynamicObject, key As %String, required As %Boolean) As %DynamicArray
{
    if '$isobject(obj) { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    if 'obj.%IsDefined(key) { if required { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") } else { return [] } }
    if obj.%GetTypeOf(key)'="array" { throw ##class(%Exception.General).%New("FHIR_INVALID_STRUCTURE") }
    quit obj.%Get(key)
}

/// Commit envelope IDs, retained source data, original response, and business ingestion atomically.
ClassMethod Process(bundle As %DynamicObject) As %DynamicObject
{
    if $length($zconvert(bundle.%ToJSON(),"O","UTF8"))>65536 { throw ##class(%Exception.General).%New("INPUT_TOO_LARGE") }
    set mapped=..Convert(bundle),raw=bundle.%ToJSON(),hash=$system.Encryption.Base64Encode($system.Encryption.SHAHash(256,$zconvert(raw,"O","UTF8")))
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        tstart
        set existing=$get(^PIData($namespace,"fhirMessage",mapped.bundleId,"header")),priorBundle=$get(^PIData($namespace,"fhirHeader",mapped.headerId))
        if (existing'="")!(priorBundle'="") {
            if (existing'=mapped.headerId)!(priorBundle'=mapped.bundleId)!($get(^PIData($namespace,"fhirMessage",mapped.bundleId,"hash"))'=hash) { throw ##class(%Exception.General).%New("FHIR_MESSAGE_ID_CONFLICT") }
            set result={}.%FromJSON(^PIData($namespace,"fhirMessage",mapped.bundleId,"response"))
        } else {
            set outcome=##class(PI.Store).Ingest(mapped.input)
            if outcome.%Get("duplicate",0),outcome.%Get("caseId","")'="" { set outcome.status=##class(PI.Store).Case(outcome.caseId).status }
            set result=..Response(mapped.headerId,mapped.event,outcome)
            set ^PIData($namespace,"fhirMessage",mapped.bundleId,"header")=mapped.headerId,^PIData($namespace,"fhirHeader",mapped.headerId)=mapped.bundleId
            set ^PIData($namespace,"fhirMessage",mapped.bundleId,"hash")=hash,^PIData($namespace,"fhirMessage",mapped.bundleId,"raw")=raw,^PIData($namespace,"fhirMessage",mapped.bundleId,"response")=result.%ToJSON()
        }
        tcommit
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"lock")
        throw ex
    }
    lock -^PIData($namespace,"lock")
    quit result
}

/// Build a synchronous R4 response message with correlated header, outcome, and structured result.
ClassMethod Response(headerId As %String, event As %DynamicObject, result As %DynamicObject) As %DynamicObject
{
    set bid=..Uuid(),hid=..Uuid(),oid=..Uuid(),pid=..Uuid(),outcomeRef="urn:uuid:"_oid,parameterRef="urn:uuid:"_pid
    set header={"resourceType":"MessageHeader","id":(hid),"eventCoding":(event),"source":{"endpoint":"urn:pi:source:identity-review"},"response":{"identifier":(headerId),"code":"ok","details":{"reference":(outcomeRef)}},"focus":[{"reference":(parameterRef)}]}
    set outcome={"resourceType":"OperationOutcome","id":(oid),"issue":[{"severity":"information","code":"informational","details":{"text":"Synthetic patient message processed; any identity association requires human review."}}]}
    set duplicate=$select(result.%Get("duplicate",0):{"name":"duplicate","valueBoolean":true},1:{"name":"duplicate","valueBoolean":false})
    set parameters=[{"name":"recordId","valueString":(result.%Get("recordId","")_"")},{"name":"status","valueString":(result.%Get("status",""))},(duplicate)]
    if result.%Get("caseId","")'="" { do parameters.%Push({"name":"caseId","valueString":(result.caseId)}) }
    set params={"resourceType":"Parameters","id":(pid),"parameter":(parameters)}
    set stamp=$translate($zdatetime($ztimestamp,3)," ","T")_"Z"
    quit {"resourceType":"Bundle","id":(bid),"type":"message","timestamp":(stamp),"entry":[{"fullUrl":("urn:uuid:"_hid),"resource":(header)},{"fullUrl":(outcomeRef),"resource":(outcome)},{"fullUrl":(parameterRef),"resource":(params)}]}
}

/// Generate FHIR-compatible UUID logical identifiers without exposing credentials.
ClassMethod Uuid() As %String
{
    quit $zconvert($translate($system.Util.CreateGUID(),"{}"),"L")
}
}
