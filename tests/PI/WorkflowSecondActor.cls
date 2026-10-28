Class PI.WorkflowSecondActor Extends PI.Workflow.Bridge
{
/// Model a second authenticated workflow member for ownership races without a production impersonation switch.
ClassMethod Actor() As %String
{
    quit "PIWorkflowSecondReviewer"
}
}
