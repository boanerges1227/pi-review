Class PI.Workflow.Service Extends Ens.BusinessService
{
Parameter ADAPTER = "";
/// Enqueue a persistent native request without holding an HTTP request open for human review.
Method Dispatch(request As PI.Workflow.TaskRequest) As %Status
{
    quit ..SendRequestAsync("ReviewDispatch",request)
}
}
