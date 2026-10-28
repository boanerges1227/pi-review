Class PI.WorkflowOtherActor Extends PI.Workflow.Bridge
{
/// Simulate a distinct server-authenticated actor without adding an impersonation parameter to production APIs.
ClassMethod Actor() As %String
{
    quit "PI-Workflow-Nonmember"
}
}
