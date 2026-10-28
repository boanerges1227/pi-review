Class PI.Authorization Extends %AI.Policy.Authorization
{
/// Check the actual tool name, case version, and allowed records before SDK execution; trace denials as well.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        set name=call.%Get("name",""),args=call.%Get("arguments",{}),id=$get(^PIData($namespace,"context",$job,"case"))
        if id="" { throw ##class(%Exception.General).%New("NO_CASE_CONTEXT") }
        // In build 154, toolref is the tool name; the source class is in native metadata.origin_class.
        if metadata.%Get("origin_class","")'="PI.Tools" { throw ##class(%Exception.General).%New("TOOL_REGISTRATION_DENIED") }
        if (toolref'=name)&&(toolref'="iris:PI.Tools") { throw ##class(%Exception.General).%New("TOOL_REGISTRATION_DENIED") }
        set c=##class(PI.Store).Case(id)
        if (c.version'=$get(^PIData($namespace,"context",$job,"version")))!c.%Get("stale",0) { throw ##class(%Exception.General).%New("STALE_CASE") }
        if (c.status="APPROVED")!(c.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
        if $get(^PIData($namespace,"context",$job,"calls"))>=8 { throw ##class(%Exception.General).%New("TOOL_LIMIT") }
        if $zh-$get(^PIData($namespace,"context",$job,"start"))>##class(PI.Agent).#DEADLINE { throw ##class(%Exception.General).%New("AGENT_TIMEOUT") }
        if '$listfind($listfromstring("get_case_summary,get_candidate_profile,get_source_history,compare_identity_fields,get_source_policy,search_governance_rules,verify_source_identity"),name) { throw ##class(%Exception.General).%New("TOOL_NOT_ALLOWED") }
        if (name="get_candidate_profile")!(name="compare_identity_fields") { set r=##class(PI.Tools).Candidate(c,args.%Get("candidateId","")) }
        if (name="get_source_history")!(name="verify_source_identity"),args.%Get("recordId","")'=c.incoming.id { set r=##class(PI.Tools).Candidate(c,args.%Get("recordId","")) }
        return 1
    } catch ex {
        do ##class(PI.ToolAudit).Record(call.%Get("name",""),"DENIED",0,ex.Name)
        return $system.Status.Error(5001,"TOOL_AUTHORIZATION_DENIED")
    }
}
}
