Class PI.Trace.Intake Extends Ens.BusinessService
{
/// Establish a real native send scope so one worker invocation and all telemetry share a Visual Trace session.
Method OnProcessInput(input As PI.Trace.RunRequest, Output output As PI.Trace.Ack, ByRef hint As %String) As %Status
{
    quit ..SendRequestSync("InvestigationWorker",input,.output,125,"AI investigation identifiers")
}
}
