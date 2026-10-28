Class PI.Workflow.Bridge Extends %RegisteredObject
{
/// Resolve the actor exclusively on the server; public callers cannot nominate another identity.
ClassMethod Actor() As %String
{
    quit $username
}

/// Require an active native workflow user and explicit membership for every claim and decision.
ClassMethod RequireMember()
{
    set actor=..Actor(),user=##class(EnsLib.Workflow.UserDefinition).%OpenId(actor)
    if '$isobject(user) { throw ##class(%Exception.General).%New("WORKFLOW_FORBIDDEN") }
    if 'user.IsActive!'##class(EnsLib.Workflow.RoleMembership).%ExistsId("IdentityReview||"_actor) { throw ##class(%Exception.General).%New("WORKFLOW_FORBIDDEN") }
}

/// Validate the case and source snapshot before touching any engine task.
ClassMethod Current(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set c=##class(PI.Store).Case(caseId)
    if (c.version'=expectedVersion)!c.%Get("stale",0) { throw ##class(%Exception.General).%New("STALE_CASE") }
    if (c.status="APPROVED")!(c.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
    if c.status="NEEDS_DATA" { throw ##class(%Exception.General).%New("WORKFLOW_WAITING_FOR_DATA") }
    set r=##class(PI.Store).Record(c.incomingId)
    if r.sourceVersion'=c.incoming.sourceVersion { throw ##class(%Exception.General).%New("STALE_CASE") }
    for i=0:1:c.candidates.%Size()-1 {
        set candidate=c.candidates.%Get(i),actual=##class(PI.Store).Record($extract(candidate.id,2,*))
        if (actual.sourceVersion'=candidate.sourceVersion)!(actual.masterId'=candidate.masterId) { throw ##class(%Exception.General).%New("STALE_CASE") }
    }
    quit c
}

/// Return persisted engine state without creating tasks or running model/Python code in readonly views.
ClassMethod View(caseId As %String, version As %Integer) As %DynamicObject
{
    set id=$get(^PIData($namespace,"workflow",caseId,version,"taskId")),result={"enabled":($get(^PIWorkflowConfig($namespace,"enabled"),0)),"taskId":(id),"assignedTo":"","status":"Not created"}
    if id'="" {
        set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(id)
        if $isobject(task) { set result.status=task.%Status,result.assignedTo=task.%TaskStatus.AssignedTo }
    }
    set result.canClaim=0,result.ownedByCurrentUser=0
    try { do ..RequireMember() set result.canClaim=1,result.ownedByCurrentUser=(result.assignedTo=..Actor()) } catch ex { }
    quit result
}

/// Deduplicate task creation under a short lock, then wait only for queue delivery, never for a human decision.
ClassMethod EnsureTask(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    do ..RequireMember()
    set c=..Current(caseId,expectedVersion)
    lock +^PIData($namespace,"workflowLock",caseId):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=..Current(caseId,expectedVersion)
        if '$data(^PIData($namespace,"workflow",caseId,expectedVersion,"dispatchId")) {
            set ^PIData($namespace,"workflow",caseId,expectedVersion,"dispatchId")=$system.Util.CreateGUID()
        }
        // A durable intent can survive a crash before enqueue. Retrying the same dispatch ID is safe at the native receiver.
        set sent=+$get(^PIData($namespace,"workflow",caseId,expectedVersion,"sentAt")),now=##class(PI.AdminSession).Now()
        if ($get(^PIData($namespace,"workflow",caseId,expectedVersion,"taskId"))="")&&((now-sent)>=10) {
            set req=##class(PI.Workflow.TaskRequest).%New()
            set req.CaseId=caseId,req.CaseVersion=expectedVersion,req.SourceVersion=c.incoming.sourceVersion,req.DispatchId=^PIData($namespace,"workflow",caseId,expectedVersion,"dispatchId")
            set req.%Subject="Patient identity review "_caseId_" v"_expectedVersion,req.%Message="Review current case evidence in PI Review; the agent cannot approve a mapping.",req.%Actions="LINK,SEPARATE,REJECT"
            set sc=##class(Ens.Director).CreateBusinessService("WorkflowIntake",.service)
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
            set sc=service.Dispatch(req)
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PRODUCTION_UNAVAILABLE") }
            set ^PIData($namespace,"workflow",caseId,expectedVersion,"sentAt")=now
        }
    } catch ex { lock -^PIData($namespace,"workflowLock",caseId) throw ex }
    lock -^PIData($namespace,"workflowLock",caseId)
    for i=1:1:50 {
        quit:$get(^PIData($namespace,"workflow",caseId,expectedVersion,"taskId"))'=""
        hang 0.1
    }
    set result=..View(caseId,expectedVersion)
    if result.taskId="" { throw ##class(%Exception.General).%New("WORKFLOW_TASK_PENDING") }
    quit result
}

/// Use native engine ownership and serialize competing claims with case-version changes.
ClassMethod Claim(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set view=..EnsureTask(caseId,expectedVersion)
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=..Current(caseId,expectedVersion),task=##class(EnsLib.Workflow.TaskResponse).%OpenId(view.taskId,4)
        if task.%TaskStatus.IsComplete { throw ##class(%Exception.General).%New("WORKFLOW_TASK_CLOSED") }
        set actor=..Actor(),owner=task.%TaskStatus.AssignedTo
        if (owner'="")&&(owner'=actor) { throw ##class(%Exception.General).%New("WORKFLOW_ALREADY_CLAIMED") }
        if owner="" {
            set sc=##class(EnsLib.Workflow.Engine).%TakeOwnershipForTask(view.taskId_"||"_actor,actor,.message)
            if $system.Status.IsError(sc)!(message'="") { throw ##class(%Exception.General).%New("WORKFLOW_CLAIM_FAILED") }
            do ##class(PI.Store).Audit(caseId,"WORKFLOW_CLAIM",view.taskId)
        }
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit ..View(caseId,expectedVersion)
}

/// Commit the mapping and completion intent together, then finish the native task outside that transaction.
ClassMethod Complete(caseId As %String, expectedVersion As %Integer, action As %String, candidateId As %String, reason As %String) As %DynamicObject
{
    do ..RequireMember()
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=..Current(caseId,expectedVersion),view=..View(caseId,expectedVersion)
        if view.taskId="" { throw ##class(%Exception.General).%New("WORKFLOW_CLAIM_REQUIRED") }
        set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(view.taskId,4)
        if task.%TaskStatus.IsComplete { throw ##class(%Exception.General).%New("WORKFLOW_TASK_CLOSED") }
        if task.%TaskStatus.AssignedTo'=..Actor() { throw ##class(%Exception.General).%New("WORKFLOW_CLAIM_REQUIRED") }
        set result=##class(PI.Review).Decide(caseId,expectedVersion,action,candidateId,reason,view.taskId)
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    do ..Recover()
    quit result
}

/// Retry durable post-commit intents; engine failures never replay a human mapping decision.
ClassMethod Recover()
{
    set id=""
    for {
        set id=$order(^PIData($namespace,"workflowCompletion",id)) quit:id=""
        lock +^PIData($namespace,"workflowCompletionLock",id):0
        if '$test { continue }
        try {
            set pending={}.%FromJSON(^PIData($namespace,"workflowCompletion",id)),task=##class(EnsLib.Workflow.TaskResponse).%OpenId(id,4)
            if '$isobject(task) { throw ##class(%Exception.General).%New("WORKFLOW_TASK_MISSING") }
            if 'task.%TaskStatus.IsComplete {
                set sc=task.CompleteTask(pending.action)
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
                set sc=task.%Save()
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            }
            // A cancelled or differently completed native task is an unresolved inconsistency, never successful delivery.
            if (task.%Status'="Completed")!(task.%Action'=pending.action) { throw ##class(%Exception.General).%New("WORKFLOW_COMPLETION_CONFLICT") }
            kill ^PIData($namespace,"workflowCompletion",id)
        } catch ex { do ##class(PI.Store).Audit(pending.caseId,"WORKFLOW_COMPLETION_PENDING",id) }
        lock -^PIData($namespace,"workflowCompletionLock",id)
    }
}

/// Cancel obsolete native worklist items without changing the underlying case decision.
ClassMethod CancelTask(taskId As %String)
{
    // Serialize with the mapping transaction and completion recovery in that lock order.
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    lock +^PIData($namespace,"workflowCompletionLock",taskId):3
    if '$test { lock -^PIData($namespace,"lock") throw ##class(%Exception.General).%New("BUSY") }
    try {
        if '$data(^PIData($namespace,"workflowCompletion",taskId)) {
            set task=##class(EnsLib.Workflow.TaskResponse).%OpenId(taskId,4)
            if $isobject(task),'task.%TaskStatus.IsComplete {
                set sc=task.CompleteTask("")
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
                set sc=task.%Save()
                if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            }
        }
    } catch ex { lock -^PIData($namespace,"workflowCompletionLock",taskId) lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"workflowCompletionLock",taskId)
    lock -^PIData($namespace,"lock")
}

/// Reconcile committed task completions and cancel worklists whose case snapshots have become obsolete.
ClassMethod Reconcile()
{
    do ..Recover()
    set caseId=""
    for {
        set caseId=$order(^PIData($namespace,"workflow",caseId)) quit:caseId=""
        set version=""
        for {
            set version=$order(^PIData($namespace,"workflow",caseId,version)) quit:version=""
            set id=$get(^PIData($namespace,"workflow",caseId,version,"taskId"))
            if id="" { continue }
            try { set c=##class(PI.Store).Case(caseId) if (c.version'=version)!c.%Get("stale",0) { do ..CancelTask(id) } } catch ex { }
        }
    }
}
}
