Class PI.Workflow.TaskResponse Extends EnsLib.Workflow.TaskResponse
{
/// Record the real engine task only after native worklist distribution succeeds.
Method OnNewTask(request As EnsLib.Workflow.TaskRequest) As %Status
{
    set sc=##super(request)
    if $system.Status.IsError(sc) { quit sc }
    lock +^PIData($namespace,"workflowLock",request.CaseId):3
    if '$test { quit ##class(%Exception.General).%New("BUSY").AsStatus() }
    set canonical=$get(^PIData($namespace,"workflow",request.CaseId,request.CaseVersion,"taskId"))
    set duplicate=($get(^PIData($namespace,"workflow",request.CaseId,request.CaseVersion,"dispatchId"))'=request.DispatchId)!((canonical'="")&&(canonical'=..%Id()))
    if 'duplicate { set ^PIData($namespace,"workflow",request.CaseId,request.CaseVersion,"taskId")=..%Id() }
    lock -^PIData($namespace,"workflowLock",request.CaseId)
    // A replay may enqueue twice around a crash; retain the first task and close only the duplicate native response.
    if duplicate { quit ..CompleteTask("") }
    quit sc
}
Storage Default
{
<Type>%Storage.Persistent</Type>
}

}
