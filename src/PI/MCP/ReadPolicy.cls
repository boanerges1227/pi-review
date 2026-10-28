Class PI.MCP.ReadPolicy Extends %AI.Policy.Authorization
{
/// Advertise only explicit readonly methods to an authenticated, still-active actor.
Method %CanList(toolref As %String, metadata As %DynamicObject) As %Boolean
{
    set actor=$get(^||PIMCP("actor")),hash=$get(^||PIMCP("hash"))
    quit (actor'="")&&($get(^PIMCPAccess($namespace,"token",hash))=actor)&&$listfind($listfromstring("review_case,review_evidence,review_run_trace"),metadata.%Get("name",""))
}

/// Enforce tool and case ACL dynamically; cached ToolManagers must never capture a prior caller.
Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    try {
        if '$listfind($listfromstring("review_case,review_evidence,review_run_trace"),call.%Get("name","")) { throw ##class(%Exception.General).%New("MCP_TOOL_DENIED") }
        if metadata.%Get("origin_class","")'="PI.MCP.ReadTools" { throw ##class(%Exception.General).%New("MCP_TOOL_DENIED") }
        set args=##class(PI.MCP.ReadAudit).Arguments(call),c=##class(PI.MCP.Access).Check(args.%Get("caseId",""),args.%Get("expectedVersion",0))
        return 1
    } catch ex {
        set args=##class(PI.MCP.ReadAudit).Arguments(call)
        do ##class(PI.MCP.ReadAudit).Record(call.%Get("name",""),"DENIED",0,args.%Get("caseId",""),+args.%Get("expectedVersion",0))
        return $system.Status.Error(5001,"MCP_READ_DENIED")
    }
}
}
