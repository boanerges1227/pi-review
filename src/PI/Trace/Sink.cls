Class PI.Trace.Sink Extends Ens.BusinessOperation
{
/// Accept the strict native telemetry schema; the Production header supplies session and parent linkage.
Method OnMessage(request As PI.Trace.Event, Output response As PI.Trace.Ack) As %Status
{
    do request.Validate()
    set response=##class(PI.Trace.Ack).%New(),response.Accepted=1
    quit 1
}
}
