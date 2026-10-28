Class PI.Route Extends Ens.BusinessOperation
{
/// Give each Production operation a distinct name so the actual branch is visible in traces.
Method OnMessage(request As PI.Message, Output response As PI.Reply) As %Status
{
    set input={}.%FromJSON(request.Payload),result=..Apply(input.caseId,input.result)
    set response=##class(PI.Reply).%New(),response.Payload=result.%ToJSON()
    quit 1
}

/// Persist routing and enrichment requests; waiting must not occupy a worker thread.
ClassMethod Apply(caseId As %String, result As %DynamicObject) As %DynamicObject
{
    set snapshot=##class(PI.Store).Case(caseId),expected=snapshot.version,task=""
    if result.%IsDefined("caseVersion"),result.caseVersion'=expected { throw ##class(%Exception.General).%New("STALE_CASE") }
    if (result.decision="NEEDS_DATA")&&(snapshot.rounds<2) {
        lock +^PIData($namespace,"lock"):3
        if '$test { throw ##class(%Exception.General).%New("BUSY") }
        try {
            set current=##class(PI.Store).Case(caseId)
            if current.version'=expected { throw ##class(%Exception.General).%New("STALE_CASE") }
            if (current.status="APPROVED")!(current.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
            if $data(^PIData($namespace,"enrichment",caseId,expected+1)) {
                set task={}.%FromJSON(^PIData($namespace,"enrichment",caseId,expected+1))
            } else {
                set task={"caseId":(caseId),"originVersion":(expected),"waitingVersion":(expected+1),"requestId":($namespace_"-"_caseId_"-"_$system.Util.CreateGUID()),"missingFields":(result.missingFields),"status":"REQUESTING","transport":"mcp","synthetic":true}
                set ^PIData($namespace,"enrichment",caseId,expected+1)=task.%ToJSON()
            }
        } catch ex { lock -^PIData($namespace,"lock") throw ex }
        lock -^PIData($namespace,"lock")
        // A slow source cannot block human decisions; recheck the case after the remote call.
        try {
            set remote=##class(PI.MCP.Client).Call(snapshot,snapshot.incoming,"request_enrichment",task),task.status=remote.status,task.receiptId=remote.receiptId
        } catch ex { set task.status="FAILED",result=##class(PI.Policy).Deny("SOURCE_MCP_UNAVAILABLE") }
    }
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=##class(PI.Store).Case(caseId)
        if (c.status="APPROVED")!(c.status="REJECTED")!(c.version'=expected) {
            // Finalize an already-created remote request even when another decision won the case.
            if $isobject(task) {
                set task.sourceStatus=task.status,task.status="SUPERSEDED",task.finalizedAt=$ztimestamp
                set ^PIData($namespace,"enrichment",caseId,expected+1)=task.%ToJSON()
                do ##class(PI.Store).Audit(caseId,"MCP_ENRICHMENT_SUPERSEDED",task.requestId)
            }
            if (c.status="APPROVED")!(c.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
            throw ##class(%Exception.General).%New("STALE_CASE")
        }
        set c.status=result.decision,c.result=result,c.mode=$select(result.%Get("error","")="MODEL_NOT_CONFIGURED":"manual-fallback",1:"live")
        if c.status="NEEDS_DATA" {
            if c.rounds>=2 { set c.status="CONFLICT_REVIEW" } else {
                set c.requestedAt=$ztimestamp,c.enrichmentVersion=expected+1
            }
        }
        if $isobject(task) { set ^PIData($namespace,"enrichment",caseId,expected+1)=task.%ToJSON() }
        set c.version=c.version+1,^PIData($namespace,"case",caseId)=c.%ToJSON()
        do ##class(PI.Store).Audit(caseId,"ROUTE",c.status)
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit c
}

/// Deduplicate demo notifications by unique ID; failures must not roll back completed human decisions.
ClassMethod Notify(id As %String)
{
    lock +^PIData($namespace,"notifyLock",id):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    set n={}.%FromJSON(^PIData($namespace,"notification",id))
    if n.status'="SENT" {
        set n.attempts=n.attempts+1,n.status=$select(n.%Get("simulateFailure",0):"FAILED",1:"SENT")
        set ^PIData($namespace,"notification",id)=n.%ToJSON()
        do ##class(PI.Store).Audit(n.caseId,"NOTIFICATION_"_n.status,id)
    }
    lock -^PIData($namespace,"notifyLock",id)
}

/// Escalate enrichment to human review after five minutes; compare absolute times to handle midnight correctly.
ClassMethod Expire()
{
    set id="",now=$ztimestamp
    for {
        set id=$order(^PIData($namespace,"case",id)) quit:id=""
        set c=##class(PI.Store).Case(id)
        if c.status="NEEDS_DATA" {
            set before=c.%Get("requestedAt",now),seconds=($piece(now,",",1)-$piece(before,",",1))*86400+$piece(now,",",2)-$piece(before,",",2)
            if seconds>=300 { do ..Apply(id,##class(PI.Policy).Deny("ENRICHMENT_TIMEOUT")) }
        }
    }
}
}
