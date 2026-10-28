Class PI.WorkflowTests Extends PI.Tests
{
/// Test native task distribution, ownership, version binding and post-commit completion.
ClassMethod Run()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.Workflow.Bridge"),"native workflow bridge is installed")
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    // Production compilation registers its configuration in this namespace's isolated globals database.
    set sc=$system.OBJ.Compile("PI.Production","ck")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    if '##class(Ens.Director).IsProductionRunning() {
        set sc=##class(Ens.Director).StartProduction("PI.Production")
    } else { set sc=##class(Ens.Director).UpdateProduction() }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    do ..Reset()
    do ..CleanupNativeTasks()
    do ##class(PI.Workflow.Setup).Install($username_",PIWorkflowSecondReviewer")
    do ..OrphanDispatch()
    do ..CancellationGuard()
    set a=##class(PI.Store).Ingest(..Input()),b=##class(PI.Store).Ingest(..Input("EMR","workflow")),c=##class(PI.Store).Case(b.caseId)
    set task=##class(PI.Workflow.Bridge).EnsureTask(c.id,c.version)
    do ..Assert(task.taskId'="","production creates a native task")
    set same=##class(PI.Workflow.Bridge).EnsureTask(c.id,c.version)
    do ..Assert(same.taskId=task.taskId,"repeated routing preserves one task")
    set native=##class(EnsLib.Workflow.TaskResponse).%OpenId(task.taskId)
    do ..Assert($isobject(native)&&(native.%RoleName="IdentityReview"),"task belongs to the real workflow role")
    set claimed=##class(PI.Workflow.Bridge).Claim(c.id,c.version)
    do ..Assert(claimed.assignedTo=$username,"native task ownership uses authenticated identity")
    set denied=0
    try { set other=##class(PI.WorkflowSecondActor).Claim(c.id,c.version) } catch ex { set denied=(ex.Name="WORKFLOW_ALREADY_CLAIMED") }
    do ..Assert(denied,"a second role member cannot take an owned task")
    set denied=0
    try { set other=##class(PI.WorkflowOtherActor).Claim(c.id,c.version) } catch ex { set denied=1 }
    do ..Assert(denied,"nonmember cannot claim an existing task")
    set denied=0
    try { set result=##class(PI.WorkflowOtherActor).Complete(c.id,c.version,"LINK","r"_a.recordId,"Denied actor") } catch ex { set denied=1 }
    do ..Assert(denied,"nonmember cannot approve through the bridge")
    set result=##class(PI.Workflow.Bridge).Complete(c.id,c.version,"LINK","r"_a.recordId,"Synthetic native workflow approval")
    do ..Assert(result.status="APPROVED","task completion invokes the guarded mapping writer")
    set native=##class(EnsLib.Workflow.TaskResponse).%OpenId(task.taskId)
    do ..Assert(native.%Status="Completed","native engine marks the task complete")
    set native=""
    set denied=0
    try { set duplicate=##class(PI.Workflow.Bridge).Complete(c.id,c.version,"LINK","r"_a.recordId,"Duplicate approval") } catch ex { set denied=1 }
    do ..Assert(denied,"duplicate completion cannot change mappings")
    set reopened=##class(PI.Review).Undo(c.id,result.version,"Synthetic undo for a fresh review cycle")
    set next=##class(PI.Workflow.Bridge).EnsureTask(c.id,reopened.version)
    do ..Assert(next.taskId'=task.taskId,"undo creates a new native task")
    set oldVersion=reopened.version,changed=..Input("EMR","workflow",2),changed.notes="Synthetic source updated"
    set ingested=##class(PI.Store).Ingest(changed),denied=0
    try { set stale=##class(PI.Workflow.Bridge).Complete(c.id,oldVersion,"LINK","r"_a.recordId,"Stale task") } catch ex { set denied=1 }
    do ..Assert(denied,"source changes invalidate old workflow tasks")
    do ##class(PI.Workflow.Bridge).Reconcile()
    set obsolete=##class(EnsLib.Workflow.TaskResponse).%OpenId(next.taskId)
    do ..Assert(obsolete.%Status="Cancelled","reconciliation removes stale native worklists")
    set obsolete=""
    // A missing native task must leave a durable intent, while the committed mapping remains unchanged.
    set third=##class(PI.Store).Ingest(..Input("EMR","workflow-recovery")),recovery=##class(PI.Store).Case(third.caseId)
    set owned=##class(PI.Workflow.Bridge).Claim(recovery.id,recovery.version)
    set decided=##class(PI.Review).Decide(recovery.id,recovery.version,"SEPARATE","","Synthetic completion recovery","missing-native-task")
    do ##class(PI.Workflow.Bridge).Recover()
    do ..Assert($data(^PIData($namespace,"workflowCompletion","missing-native-task")),"failed engine completion retains its durable intent")
    do ..Assert(##class(PI.Store).Case(recovery.id).version=decided.version,"completion failure does not replay the mapping decision")
    set ^PIData($namespace,"workflowCompletion",owned.taskId)=^PIData($namespace,"workflowCompletion","missing-native-task")
    kill ^PIData($namespace,"workflowCompletion","missing-native-task")
    do ##class(PI.Workflow.Bridge).Recover()
    do ..Assert('$data(^PIData($namespace,"workflowCompletion",owned.taskId)),"recovery consumes a successful native completion intent")
    do ..Assert(##class(PI.Store).Case(recovery.id).version=decided.version,"successful recovery still preserves the decided case version")
    set sc=##class(EnsLib.Workflow.RoleDefinition).RemoveUserFromRole("IdentityReview","PIWorkflowSecondReviewer")
    set sc=##class(EnsLib.Workflow.UserDefinition).DeleteUser("PIWorkflowSecondReviewer")
    write "WORKFLOW_TESTS_OK",!
}

/// Remove only native tasks created by this test package in PITEST, including leftovers from interrupted runs.
ClassMethod CleanupNativeTasks()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    set rows=##class(%SQL.Statement).%ExecDirect(,"SELECT ID FROM PI_Workflow.TaskResponse WHERE %Status NOT IN ('Completed','Cancelled')")
    while rows.%Next() { do ##class(PI.Workflow.Bridge).CancelTask(rows.%Get("ID")) }
}

/// A crash after writing a dispatch intent must not permanently prevent the native task from being created.
ClassMethod OrphanDispatch()
{
    set input=..Input("HIS","orphan-base"),input.identifier="SYN-ORPHAN",input.name="Orphan Dispatch"
    set a=##class(PI.Store).Ingest(input),input.sourceSystem="EMR",b=##class(PI.Store).Ingest(input)
    set c=##class(PI.Store).Case(b.caseId)
    set dispatchId="interrupted-"_$system.Util.CreateGUID(),^PIData($namespace,"workflow",c.id,c.version,"dispatchId")=dispatchId
    set task=##class(PI.Workflow.Bridge).EnsureTask(c.id,c.version)
    do ..Assert(task.taskId'="","orphan dispatch intents are retried instead of blocking review forever")
    set replay=##class(PI.Workflow.TaskRequest).%New(),replay.CaseId=c.id,replay.CaseVersion=c.version,replay.SourceVersion=c.incoming.sourceVersion,replay.DispatchId=dispatchId
    set replay.%Subject="Synthetic replay",replay.%Actions="LINK,SEPARATE,REJECT"
    set sc=##class(Ens.Director).CreateBusinessService("WorkflowIntake",.service),sc=service.Dispatch(replay),closed=0
    for i=1:1:50 {
        set rows=##class(%SQL.Statement).%ExecDirect(,"SELECT ID FROM PI_Workflow.TaskResponse WHERE %Status='Cancelled'")
        while rows.%Next() {
            set native=##class(EnsLib.Workflow.TaskResponse).%OpenId(rows.%Get("ID"))
            if native.%TaskStatus.Request.%IsA("PI.Workflow.TaskRequest"),native.%TaskStatus.Request.DispatchId=dispatchId { set closed=closed+1 }
            set native=""
        }
        quit:closed>0
        hang 0.1
    }
    do ..Assert(closed=1,"duplicate dispatch closes only its duplicate native task")
    do ..Assert(##class(PI.Workflow.Bridge).View(c.id,c.version).taskId=task.taskId,"duplicate delivery preserves the canonical usable task")
    do ##class(PI.Workflow.Bridge).CancelTask(task.taskId)
}

/// Obsolete-worklist cleanup must preserve an already committed human decision and its native completion intent.
ClassMethod CancellationGuard()
{
    set input=..Input("HIS","cancel-base"),input.identifier="SYN-CANCEL-GUARD",input.name="Cancellation Guard"
    set a=##class(PI.Store).Ingest(input),input.sourceSystem="EMR",b=##class(PI.Store).Ingest(input)
    set c=##class(PI.Store).Case(b.caseId),task=##class(PI.Workflow.Bridge).Claim(c.id,c.version)
    set decided=##class(PI.Review).Decide(c.id,c.version,"SEPARATE","","Synthetic interruption before engine completion",task.taskId)
    do ##class(PI.Workflow.Bridge).CancelTask(task.taskId)
    do ##class(PI.Workflow.Bridge).Recover()
    set native=##class(EnsLib.Workflow.TaskResponse).%OpenId(task.taskId)
    do ..Assert(native.%Status="Completed","reconciliation cannot cancel a committed decision's native task")
    do ..Assert(native.%Action="SEPARATE","native completion preserves the actual human action")
    do ..Assert(##class(PI.Store).Case(c.id).version=decided.version,"reconciliation does not replay the committed mapping")
    do ..Assert('$data(^PIData($namespace,"workflowCompletion",task.taskId)),"successful recovery removes only a matching completion intent")
}
}
