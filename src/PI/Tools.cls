Class PI.Tools Extends %AI.ToolSet
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="IdentityEvidence">
  <Tool Name="get_case_summary" Method="Summary"><Description>Read the current identity case, candidate IDs and known missing fields.</Description></Tool>
  <Tool Name="get_candidate_profile" Method="Profile"><Description>Read an allowed candidate snapshot by candidateId.</Description></Tool>
  <Tool Name="get_source_history" Method="History"><Description>Read prior versions of the incoming record or an allowed candidate by recordId.</Description></Tool>
  <Tool Name="compare_identity_fields" Method="Compare"><Description>Compare incoming and candidate fields. Different nonempty identifiers are a hard conflict.</Description></Tool>
  <Tool Name="get_source_policy" Method="SourcePolicy"><Description>Read synthetic source policy and whether enrichment is available.</Description></Tool>
  <Tool Name="search_governance_rules" Method="SearchGovernance"><Description>Search versioned synthetic identity governance rules. Required before a recommendation; cite its evidenceId. Returns actual retrieved document chunks and policy version.</Description></Tool>
  <Tool Name="verify_source_identity" Method="VerifySource"><Description>Verify the incoming record or an allowed candidate against its independent source MCP at the exact snapshot version. Required for incoming and for the chosen candidate before LINK_REVIEW. Cite this evidenceId.</Description></Tool>
</ToolSet>
}

/// Bind investigation context through the workflow; the model cannot select another case.
ClassMethod Begin(caseId As %String)
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=##class(PI.Store).Case(caseId)
        if (c.status="APPROVED")!(c.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
        // Save investigation metadata separately instead of rewriting the case to avoid overwriting concurrent human review.
        set ^PIData($namespace,"evidenceVersion",caseId)=c.version
        kill ^PIData($namespace,"context",$job)
        set ^PIData($namespace,"context",$job,"case")=caseId,^PIData($namespace,"context",$job,"version")=c.version
        set ^PIData($namespace,"context",$job,"start")=$zh,^PIData($namespace,"context",$job,"calls")=0
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
}

/// Clear the current process context after investigation to prevent reuse across requests.
ClassMethod End()
{
    kill ^PIData($namespace,"context",$job)
}

/// Check the case version, total call count, and elapsed time on every tool call.
ClassMethod Context() As %DynamicObject
{
    set id=$get(^PIData($namespace,"context",$job,"case"))
    if id="" { throw ##class(%Exception.General).%New("NO_CASE_CONTEXT") }
    set c=##class(PI.Store).Case(id)
    if c.version'=$get(^PIData($namespace,"context",$job,"version")) { throw ##class(%Exception.General).%New("STALE_CASE") }
    if $zh-^PIData($namespace,"context",$job,"start")>##class(PI.Agent).#DEADLINE { throw ##class(%Exception.General).%New("AGENT_TIMEOUT") }
    if $increment(^PIData($namespace,"context",$job,"calls"))>8 { throw ##class(%Exception.General).%New("TOOL_LIMIT") }
    quit c
}

/// Return only case snapshots so an investigation cannot mix facts from different versions.
ClassMethod Candidate(c As %DynamicObject, id As %String) As %DynamicObject
{
    for i=0:1:c.candidates.%Size()-1 {
        set r=c.candidates.%Get(i)
        if r.id=id { return r }
    }
    throw ##class(%Exception.General).%New("CANDIDATE_DENIED")
}

/// Use immutable evidence IDs to record actual tool calls rather than calls claimed by the model.
ClassMethod Evidence(c As %DynamicObject, kind As %String, payload As %DynamicObject) As %DynamicObject
{
    set n=$increment(^PIData($namespace,"seq","evidence")),id=c.id_"v"_c.version_"e"_n
    set e={"evidenceId":(id),"caseId":(c.id),"caseVersion":(c.version),"runId":($get(^PIData($namespace,"context",$job,"runId"))),"tool":(kind),"data":(payload),"time":($zdatetime($horolog,3))}
    if $length($zconvert(e.%ToJSON(),"O","UTF8"))>12000 { throw ##class(%Exception.General).%New("EVIDENCE_TOO_LARGE") }
    set ^PIData($namespace,"evidence",c.id,c.version,id)=e.%ToJSON()
    do ##class(PI.Store).Audit(c.id,"TOOL_CALL",kind_":"_id)
    quit e
}

/// Return the current case summary; patient text remains untrusted input.
ClassMethod Summary() As %DynamicObject
{
    set c=..Context()
    quit ..Evidence(c,"get_case_summary",{"incoming":(c.incoming),"candidates":(c.candidates),"truncated":(c.truncated),"rounds":(c.rounds)})
}

/// Return only allowed candidate records without executing arbitrary database queries.
ClassMethod Profile(candidateId As %String) As %DynamicObject
{
    set c=..Context(),r=..Candidate(c,candidateId)
    quit ..Evidence(c,"get_candidate_profile",r)
}

/// Allow history reads only for the incoming record or this case's candidates, limited to five versions.
ClassMethod History(recordId As %String) As %DynamicObject
{
    set c=..Context()
    if recordId'=c.incoming.id { set r=..Candidate(c,recordId) }
    set rid=$extract(recordId,2,*),v="",a=[]
    for { set v=$order(^PIData($namespace,"version",rid,v),-1) quit:v=""  do a.%Push({}.%FromJSON(^PIData($namespace,"version",rid,v))) quit:a.%Size()=5 }
    quit ..Evidence(c,"get_source_history",{"recordId":(recordId),"versions":(a)})
}

/// Preserve hard identifier conflicts through deterministic comparison; do not let the model infer field equality.
ClassMethod Compare(candidateId As %String) As %DynamicObject
{
    set c=..Context(),r=..Candidate(c,candidateId),data=##class(PI.Rules).Compare(c.incoming,r)
    set data.candidateId=candidateId
    quit ..Evidence(c,"compare_identity_fields",data)
}

/// Source authority is demo configuration and must not be described as real hospital policy.
ClassMethod SourcePolicy() As %DynamicObject
{
    set c=..Context()
    quit ..Evidence(c,"get_source_policy",{"synthetic":true,"enrichmentAvailable":true,"policy":"Identifiers require human confirmation; names, phones and addresses alone do not prove identity."})
}
/// Wrap native RAG with controlled access so policy chunks also receive immutable evidence IDs bound to the current case and version.
ClassMethod SearchGovernance(query As %String) As %DynamicObject
{
    set c=..Context(),data=##class(PI.Governance).Search(query)
    quit ..Evidence(c,"search_governance_rules",data)
}
/// Compare actual MCP source fields with the exact allowed snapshot, not the latest remote version.
ClassMethod VerifySource(recordId As %String) As %DynamicObject
{
    set c=..Context(),record=c.incoming
    if recordId'=record.id { set record=..Candidate(c,recordId) }
    try {
        set data=##class(PI.MCP.Client).Call(c,record,"verify_source_record"),data.recordId=recordId
        if data.status="VERIFIED" {
            set actual=data.%Get("record",{}),differences=[]
            for key="sourceSystem","sourcePatientId","sourceVersion","name","birthDate","sex","identifier","phone" {
                if actual.%Get(key,"")'=record.%Get(key,"") { do differences.%Push(key) }
            }
            if differences.%Size()>0 { set data.status="MISMATCH",data.differences=differences }
        }
    } catch ex { set data={"status":"UNAVAILABLE","recordId":(recordId),"transport":"mcp","server":"synthetic-source"} }
    quit ..Evidence(c,"verify_source_identity",data)
}
}
