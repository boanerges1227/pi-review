Class PI.Trace.Worker Extends Ens.BusinessOperation
{
Parameter INVOCATION = "InProc";

/// Keep the existing isolated job, timeout and SDK loop while giving every observation a native parent.
Method OnMessage(request As PI.Trace.RunRequest, Output response As PI.Trace.Ack) As %Status
{
    new %PITraceScope,%PITraceModelStarted
    set %PITraceModelStarted=0
    set response=##class(PI.Trace.Ack).%New(),c=##class(PI.Store).Case(request.CaseId)
    set %PITraceScope=##class(PI.Trace.Scope).Start($this,request.RunId,request.CaseId,c.version,..%SessionId)
    try {
        do ##class(PI.Agent).WorkerCore(request.CaseId,request.RunId)
    } catch ex {
        do ##class(PI.Agent).TraceFailure(request.CaseId,request.RunId,%PITraceModelStarted,0)
    }
    set result=##class(PI.Policy).Deny("TRACE_FAILED")
    if $data(^PIData($namespace,"traceWork",request.RunId)) { set result={}.%FromJSON(^PIData($namespace,"traceWork",request.RunId)) }
    set succeeded=(result.%Get("error","")="")
    do %PITraceScope.Finish(succeeded)
    if %PITraceScope.Failed {
        set result=##class(PI.Policy).Deny("TRACE_FAILED")
        if $data(^PIData($namespace,"traceRun",request.CaseId,request.RunId)) {
            set run={}.%FromJSON(^PIData($namespace,"traceRun",request.CaseId,request.RunId)),run.error="TRACE_FAILED",run.decision=result.decision
            set ^PIData($namespace,"traceRun",request.CaseId,request.RunId)=run.%ToJSON()
        }
    }
    if $data(^PIData($namespace,"traceRun",request.CaseId,request.RunId)) { set ^PIData($namespace,"run",request.CaseId,request.RunId)=^PIData($namespace,"traceRun",request.CaseId,request.RunId) }
    set ^PIData($namespace,"work",request.RunId)=result.%ToJSON()
    kill ^PIData($namespace,"traceWork",request.RunId),^PIData($namespace,"traceRun",request.CaseId,request.RunId)
    set response.Accepted=1,response.TraceId=%PITraceScope.TraceId,response.NativeSessionId=..%SessionId
    quit 1
}
}
