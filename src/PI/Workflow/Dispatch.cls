Class PI.Workflow.Dispatch Extends Ens.BusinessProcess
{
/// Suspend through the interoperability framework while the native Workflow operation awaits a human.
Method OnRequest(request As PI.Workflow.TaskRequest, Output response As %Persistent) As %Status
{
    quit ..SendRequestAsync("IdentityReview",request,1)
}

/// Consume the deferred native response so completion is visible in the same Production trace.
Method OnResponse(request As PI.Workflow.TaskRequest, ByRef response As %Persistent, callrequest As %Persistent, callresponse As %Persistent, pCompletionKey As %String) As %Status
{
    set response=##class(PI.Reply).%New(),response.Payload={"caseId":(request.CaseId),"workflowStatus":(callresponse.%Status)}.%ToJSON()
    quit 1
}
Storage Default
{
<Type>%Storage.Persistent</Type>
}

}
