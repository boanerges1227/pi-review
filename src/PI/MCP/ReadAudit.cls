Class PI.MCP.ReadAudit Extends %AI.Policy.Audit
{
/// Persist only actor, tool, outcome, and duration; never capture authorization or raw arguments.
Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    set args=..Arguments(call)
    do ..Record(call.%Get("name",""),$select($system.Status.IsOK(status):"ALLOWED",1:"FAILED"),duration,args.%Get("caseId",""),+args.%Get("expectedVersion",0))
    quit 1
}

/// Build154 audit callbacks pass JSON strings; normalize without retaining raw request text.
ClassMethod Arguments(call As %DynamicObject) As %DynamicObject
{
    set args=call.%Get("arguments",{})
    if '$isobject(args) {
        if $length(args)>8192 { return {} }
        try { set args={}.%FromJSON(args) } catch ex { return {} }
    }
    if 'args.%IsA("%DynamicObject") { quit {} }
    quit args
}

/// Keep a dedicated audit separate from investigation context and immutable evidence pointers.
ClassMethod Record(tool As %String, outcome As %String, duration As %Integer, caseId As %String = "", caseVersion As %Integer = 0)
{
    if caseId'?1"c"1.N { set caseId="" }
    set stamp=$ztimestamp,epoch=(($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
    set id=$increment(^PIMCPAccess($namespace,"auditSeq"))
    set ^PIMCPAccess($namespace,"audit",id)={"occurredAtEpoch":(epoch),"caseId":(caseId),"caseVersion":(caseVersion),"actor":($get(^||PIMCP("actor"))),"tool":(tool),"outcome":(outcome),"durationMs":(duration),"time":($zdatetime($horolog,3))}.%ToJSON()
}
}
