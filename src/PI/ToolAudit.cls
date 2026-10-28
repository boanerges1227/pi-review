Class PI.ToolAudit Extends %AI.Policy.Audit
{
/// Record actual execution results through native SDK callbacks; exclude raw arguments, outputs, and external exception text.
Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    set outcome=$select($system.Status.IsOK(status):"ALLOWED",1:"FAILED")
    do ..Record(call.%Get("name",""),outcome,duration,$select(outcome="FAILED":"TOOL_EXECUTION_FAILED",1:""))
    quit 1
}

/// Bind every event to the server process's case, round, and version; the model cannot set these fields.
ClassMethod Record(tool As %String, outcome As %String, duration As %Numeric = 0, code As %String = "")
{
    set id=$get(^PIData($namespace,"context",$job,"case"))
    if id="" { quit }
    set n=$increment(^PIData($namespace,"seq","trace"))
    set t={"traceId":(n),"caseId":(id),"caseVersion":($get(^PIData($namespace,"context",$job,"version"))),"runId":($get(^PIData($namespace,"context",$job,"runId"))),"tool":(tool),"outcome":(outcome),"durationMs":(duration),"code":(code),"time":($zdatetime($horolog,3))}
    set ^PIData($namespace,"trace",id,n)=t.%ToJSON()
}

/// Return at most the latest one hundred native tool events.
ClassMethod List(caseId As %String) As %DynamicArray
{
    set a=[],n=""
    for { set n=$order(^PIData($namespace,"trace",caseId,n),-1) quit:n=""  do a.%Push({}.%FromJSON(^PIData($namespace,"trace",caseId,n))) quit:a.%Size()=100 }
    quit a
}
}
