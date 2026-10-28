Class PI.Policy Extends %RegisteredObject
{
/// Escalate every failure to human review; never interpret invalid output or model errors as approval.
ClassMethod Deny(code As %String) As %DynamicObject
{
    quit {"decision":"CONFLICT_REVIEW","error":(code),"reasonSummary":"Manual review required; agent output did not pass validation."}
}

/// Validate structure, actual evidence, candidate permissions, and hard identifier conflicts.
ClassMethod Validate(caseId As %String, d As %DynamicObject, requireGovernance As %Boolean = 0, expectedRunId As %Integer = 0, requireMCP As %Boolean = 0) As %DynamicObject
{
    set c=##class(PI.Store).Case(caseId)
    if '$isobject(d) { quit ..Deny("INVALID_AGENT_JSON") }
    if (d.%Get("caseId")'=caseId)!(d.%Get("caseVersion")'=c.version) { quit ..Deny("STALE_CASE") }
    set decision=d.%Get("decision","")
    if '((decision="LINK_REVIEW")!(decision="SEPARATE_REVIEW")!(decision="NEEDS_DATA")!(decision="CONFLICT_REVIEW")) { quit ..Deny("INVALID_DECISION") }
    if c.%Get("stale",0)!c.truncated { quit ..Deny("STALE_OR_TRUNCATED") }
    if ('$isobject(d.%Get("evidenceIds")))||('$isobject(d.%Get("missingFields")))||('$isobject(d.%Get("conflicts"))) { quit ..Deny("INVALID_AGENT_SCHEMA") }
    if d.evidenceIds.%Size()=0 { quit ..Deny("MISSING_EVIDENCE") }
    for i=0:1:d.evidenceIds.%Size()-1 {
        if '$data(^PIData($namespace,"evidence",caseId,c.version,d.evidenceIds.%Get(i))) { return ..Deny("INVALID_EVIDENCE") }
        if expectedRunId>0 {
            set e={}.%FromJSON(^PIData($namespace,"evidence",caseId,c.version,d.evidenceIds.%Get(i)))
            if e.%Get("runId",0)'=expectedRunId { return ..Deny("CURRENT_RUN_EVIDENCE_REQUIRED") }
        }
    }
    if requireGovernance {
        set hasPolicy=0
        for i=0:1:d.evidenceIds.%Size()-1 {
            set e={}.%FromJSON(^PIData($namespace,"evidence",caseId,c.version,d.evidenceIds.%Get(i)))
            if e.tool="search_governance_rules",##class(PI.Governance).IsCurrent(e.data) { set hasPolicy=1 }
        }
        if 'hasPolicy { return ..Deny("CURRENT_GOVERNANCE_REQUIRED") }
    }
    if requireMCP {
        set incomingProof=0,candidateProof=0
        for i=0:1:d.evidenceIds.%Size()-1 {
            set e={}.%FromJSON(^PIData($namespace,"evidence",caseId,c.version,d.evidenceIds.%Get(i)))
            if e.tool="verify_source_identity",e.data.%Get("status","")="VERIFIED",e.data.%Get("receiptId","")'="",e.data.%Get("transport","")="mcp" {
                if e.data.recordId=c.incoming.id { set incomingProof=1 }
                if e.data.recordId=d.%Get("candidateId","") { set candidateProof=1 }
            }
        }
        if 'incomingProof { return ..Deny("SOURCE_VERIFICATION_REQUIRED") }
        if (decision="LINK_REVIEW")&&'candidateProof { return ..Deny("CANDIDATE_SOURCE_REQUIRED") }
    }
    if (decision="LINK_REVIEW")!(decision="SEPARATE_REVIEW") {
        try { set r=##class(PI.Tools).Candidate(c,d.%Get("candidateId","")) } catch ex { return ..Deny("CANDIDATE_DENIED") }
        set comparison=##class(PI.Rules).Compare(c.incoming,r)
        if (decision="LINK_REVIEW")&&comparison.identifierConflict { quit ..Deny("IDENTIFIER_CONFLICT") }
        set hasComparison=0,hasHistory=0
        for i=0:1:d.evidenceIds.%Size()-1 {
            set evidence={}.%FromJSON(^PIData($namespace,"evidence",caseId,c.version,d.evidenceIds.%Get(i)))
            if evidence.tool="compare_identity_fields",evidence.data.candidateId=r.id { set hasComparison=1 }
            if evidence.tool="get_source_history" {
                for j=0:1:evidence.data.versions.%Size()-1 {
                    set historic=evidence.data.versions.%Get(j)
                    if (evidence.data.recordId=r.id)&&(historic.identifier=r.identifier)&&(##class(PI.Rules).NameKey(historic.name)=##class(PI.Rules).NameKey(c.incoming.name)) { set hasHistory=1 }
                    if (evidence.data.recordId=c.incoming.id)&&(historic.identifier=c.incoming.identifier)&&(##class(PI.Rules).NameKey(historic.name)=##class(PI.Rules).NameKey(r.name)) { set hasHistory=1 }
                }
            }
        }
        if 'hasComparison { quit ..Deny("CANDIDATE_COMPARISON_REQUIRED") }
        if decision="LINK_REVIEW" {
            if (c.incoming.identifier="")!(r.identifier="")!(c.incoming.birthDate="")!(r.birthDate="") { quit ..Deny("INSUFFICIENT_IDENTITY_EVIDENCE") }
            if (c.incoming.birthDate'=r.birthDate)!(c.incoming.sex'=r.sex) { quit ..Deny("DEMOGRAPHIC_CONFLICT") }
            if (##class(PI.Rules).NameKey(c.incoming.name)'=##class(PI.Rules).NameKey(r.name))&&'hasHistory { quit ..Deny("NAME_HISTORY_REQUIRED") }
        }
    }
    if decision="NEEDS_DATA" {
        if (d.missingFields.%Size()=0)!(c.rounds>=2) { quit ..Deny("ENRICHMENT_LIMIT") }
        for i=0:1:d.missingFields.%Size()-1 {
            set k=d.missingFields.%Get(i)
            if (k'="identifier")&&(k'="birthDate")&&(k'="name")&&(k'="sex")&&(k'="phone") { return ..Deny("INVALID_MISSING_FIELD") }
        }
    }
    if $length(d.%Get("reasonSummary",""))>2000 { quit ..Deny("SUMMARY_TOO_LONG") }
    quit d
}
}
