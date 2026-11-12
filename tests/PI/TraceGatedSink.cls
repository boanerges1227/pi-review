Class PI.TraceGatedSink Extends PI.Trace.Sink
{
/// Delay or reject only the final synthetic trace acknowledgement to test result publication ordering.
Method OnMessage(request As PI.Trace.Event, Output response As PI.Trace.Ack) As %Status
{
    if (request.Kind="run.end")&&$get(^PITraceGate(request.RunId,"block")) {
        set ^PITraceGate(request.RunId,"entered")=1
        for i=1:1:400 { quit:$get(^PITraceGate(request.RunId,"release"))  hang 0.025 }
        if $get(^PITraceGate(request.RunId,"reject")) { quit $system.Status.Error(5001,"Synthetic final acknowledgement rejected") }
    }
    quit ##super(request,.response)
}
}
