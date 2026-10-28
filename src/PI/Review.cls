Class PI.Review Extends %RegisteredObject
{
/// Validate case and source snapshots under a transaction and lock; reject stale or duplicate human confirmations.
ClassMethod Decide(caseId As %String, version As %Integer, action As %String, candidateId As %String, reason As %String, workflowTaskId As %String = "") As %DynamicObject
{
    if ($length($zstrip(reason,"<>W"))<3)!($length(reason)>2000) { throw ##class(%Exception.General).%New("REASON_REQUIRED") }
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        tstart
        set c=##class(PI.Store).Case(caseId)
        if (c.version'=version)!c.%Get("stale",0) { throw ##class(%Exception.General).%New("STALE_CASE") }
        if (c.status="APPROVED")!(c.status="REJECTED") { throw ##class(%Exception.General).%New("CASE_CLOSED") }
        set r=##class(PI.Store).Record(c.incomingId),oldMaster=r.masterId
        if r.sourceVersion'=c.incoming.sourceVersion { throw ##class(%Exception.General).%New("STALE_CASE") }
        if action="LINK" {
            set target=##class(PI.Tools).Candidate(c,candidateId),current=##class(PI.Store).Record($extract(target.id,2,*))
            if (current.sourceVersion'=target.sourceVersion)!(current.masterId'=target.masterId) { throw ##class(%Exception.General).%New("STALE_CASE") }
            set comparison=##class(PI.Rules).Compare(r,target)
            if comparison.identifierConflict { throw ##class(%Exception.General).%New("IDENTIFIER_CONFLICT") }
            if target.masterId="" { throw ##class(%Exception.General).%New("TARGET_NOT_LINKED") }
            set r.masterId=target.masterId,c.status="APPROVED"
        } elseif action="SEPARATE" {
            // An explicit human decision to separate creates an independent master index instead of reusing the previously shared mapping.
            set r.masterId="m"_$increment(^PIData($namespace,"seq","master"))
            set c.status="APPROVED"
        } elseif action="REJECT" {
            set c.status="REJECTED"
        } else { throw ##class(%Exception.General).%New("INVALID_ACTION") }
        set c.version=c.version+1,c.review={"action":(action),"reason":(reason),"oldMasterId":(oldMaster),"newMasterId":(r.masterId),"sourceVersion":(r.sourceVersion)}
        set ^PIData($namespace,"record",c.incomingId)=r.%ToJSON(),^PIData($namespace,"case",caseId)=c.%ToJSON()
        do ##class(PI.Store).Audit(caseId,"HUMAN_"_action,reason)
        set notification=..Notification(caseId,r.masterId,"APPROVAL")
        // Persist the native completion intent in the same transaction as the mapping, before any deferred response.
        if workflowTaskId'="" { set ^PIData($namespace,"workflowCompletion",workflowTaskId)={"caseId":(caseId),"action":(action),"version":(c.version)}.%ToJSON() }
        tcommit
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"lock")
        throw ex
    }
    lock -^PIData($namespace,"lock")
    do ##class(PI.Route).Notify(notification)
    quit c
}

/// Undo only the latest confirmation whose source version is unchanged; never physically delete original records.
ClassMethod Undo(caseId As %String, version As %Integer, reason As %String) As %DynamicObject
{
    if $length($zstrip(reason,"<>W"))<3 { throw ##class(%Exception.General).%New("REASON_REQUIRED") }
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        tstart
        set c=##class(PI.Store).Case(caseId),r=##class(PI.Store).Record(c.incomingId)
        if (c.version'=version)!(c.status'="APPROVED") { throw ##class(%Exception.General).%New("STALE_CASE") }
        if (r.masterId'=c.review.newMasterId)!(r.sourceVersion'=c.review.sourceVersion) { throw ##class(%Exception.General).%New("STALE_CASE") }
        set r.masterId=c.review.oldMasterId,c.status="CONFLICT_REVIEW",c.version=c.version+1
        set ^PIData($namespace,"record",c.incomingId)=r.%ToJSON(),^PIData($namespace,"case",caseId)=c.%ToJSON()
        do ##class(PI.Store).Audit(caseId,"HUMAN_UNDO",reason)
        set notification=..Notification(caseId,r.masterId,"CORRECTION")
        tcommit
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"lock")
        throw ex
    }
    lock -^PIData($namespace,"lock")
    do ##class(PI.Route).Notify(notification)
    quit c
}

/// Keep notifications outside the linking transaction so failures can be retried idempotently with the same ID.
ClassMethod Notification(caseId As %String, masterId As %String, kind As %String) As %String
{
    set id="n"_$increment(^PIData($namespace,"seq","notification"))
    set ^PIData($namespace,"notification",id)={"id":(id),"caseId":(caseId),"masterId":(masterId),"kind":(kind),"status":"PENDING","attempts":0,"simulated":true}.%ToJSON()
    quit id
}
}
