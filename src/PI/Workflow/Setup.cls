Class PI.Workflow.Setup Extends %RegisteredObject
{
/// Register explicitly selected existing identities with the native workflow role; create no security accounts or grants.
ClassMethod Install(reviewers As %String = "_SYSTEM")
{
    if '##class(EnsLib.Workflow.RoleDefinition).%ExistsId("IdentityReview") {
        set sc=##class(EnsLib.Workflow.RoleDefinition).CreateRole("IdentityReview")
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    for i=1:1:$length(reviewers,",") {
        set user=$piece(reviewers,",",i)
        if user="" { continue }
        if '##class(EnsLib.Workflow.UserDefinition).%ExistsId(user) {
            set sc=##class(EnsLib.Workflow.UserDefinition).CreateUser(user)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        }
        if '##class(EnsLib.Workflow.RoleMembership).%ExistsId("IdentityReview||"_user) {
            set sc=##class(EnsLib.Workflow.RoleDefinition).AddUserToRole("IdentityReview",user)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        }
    }
    set ^PIWorkflowConfig($namespace,"enabled")=1
}
}
