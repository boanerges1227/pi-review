Class PI.Notification.Outbox Extends %RegisteredObject
{
/// Use UTC seconds for retry deadlines and leases, including across midnight and process restarts.
ClassMethod Now() As %Numeric
{
    set stamp=$ztimestamp
    quit $piece(stamp,",",1)*86400+$piece(stamp,",",2)
}

/// Capture the committed decision's immutable wire snapshot inside the caller's review transaction.
ClassMethod Create(caseId As %String, masterId As %String, kind As %String) As %String
{
    if '$tlevel { throw ##class(%Exception.General).%New("NOTIFICATION_TRANSACTION_REQUIRED") }
    set c=##class(PI.Store).Case(caseId),r=c.incoming,seq=$increment(^PIData($namespace,"seq","notification")),id="n"_seq
    set eventId="pi-"_$system.Util.CreateGUID(),action=$select(kind="CORRECTION":"UNDO",1:c.review.action)
    set previous=$select(kind="CORRECTION":c.review.newMasterId,1:c.review.oldMasterId)
    set payload={"schemaVersion":1,"eventId":(eventId),"caseId":(caseId),"caseVersion":(c.version),"sourceSystem":(r.sourceSystem),"sourcePatientId":(r.sourcePatientId),"sourceVersion":(r.sourceVersion),"kind":(kind),"action":(action),"previousMasterId":(previous),"masterId":(masterId),"occurredAt":($translate($zdatetime($ztimestamp,3,1)," ","T")_"Z")}
    set previousId=$get(^PIData($namespace,"notificationLast",r.sourceSystem,r.sourcePatientId))
    set n={"id":(id),"sequence":(seq),"caseId":(caseId),"masterId":(masterId),"kind":(kind),"status":"PENDING","attempts":0,"cycleAttempts":0,"simulated":false,"transport":"http","payload":(payload),"previousId":(previousId),"nextAttemptAt":0}
    set ^PIData($namespace,"notification",id)=n.%ToJSON(),^PIData($namespace,"notificationPending",seq)=id
    set ^PIData($namespace,"notificationLast",r.sourceSystem,r.sourcePatientId)=id
    quit id
}

/// Lease due work before queuing; a dead relay or worker becomes eligible again after sixty seconds.
ClassMethod Claim(id As %String) As %Boolean
{
    // Raw globals expose uncommitted writes. Share the review lock only while claiming committed work.
    lock +^PIData($namespace,"lock"):0
    if '$test { quit 0 }
    lock +^PIData($namespace,"notifyLock",id):0
    if '$test { lock -^PIData($namespace,"lock") quit 0 }
    set ready=0
    try {
        set raw=$get(^PIData($namespace,"notification",id))
        if raw'="" {
            set n={}.%FromJSON(raw),now=..Now()
            if (n.%Get("simulated",1)=0)&&(n.status'="SENT")&&(n.status'="FAILED")&&(n.nextAttemptAt<=now) {
                set prior=n.%Get("previousId",""),ordered=1
                if prior'="" {
                    set ordered=0
                    if $data(^PIData($namespace,"notification",prior)) { set p={}.%FromJSON(^PIData($namespace,"notification",prior)),ordered=(p.status="SENT") }
                }
                if ordered {
                    set n.status="QUEUED",n.nextAttemptAt=now+60
                    set ^PIData($namespace,"notification",id)=n.%ToJSON(),ready=1
                }
            }
        }
    } catch ex { lock -^PIData($namespace,"notifyLock",id) lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"notifyLock",id)
    lock -^PIData($namespace,"lock")
    quit ready
}

/// Release a failed queue submission without counting it as an HTTP delivery attempt.
ClassMethod QueueFailed(id As %String)
{
    lock +^PIData($namespace,"notifyLock",id):1
    if '$test { quit }
    try {
        set n={}.%FromJSON(^PIData($namespace,"notification",id))
        if n.status="QUEUED" {
            set n.status="RETRY",n.nextAttemptAt=..Now()+5,n.lastError="QUEUE_UNAVAILABLE"
            set ^PIData($namespace,"notification",id)=n.%ToJSON()
        }
    } catch ex { lock -^PIData($namespace,"notifyLock",id) throw ex }
    lock -^PIData($namespace,"notifyLock",id)
}

/// Explicitly reopen an exhausted event while retaining its payload, event ID and lifetime attempt count.
ClassMethod Retry(id As %String)
{
    if $tlevel { throw ##class(%Exception.General).%New("NOTIFICATION_RETRY_TRANSACTION_UNSUPPORTED") }
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    lock +^PIData($namespace,"notifyLock",id):3
    if '$test { lock -^PIData($namespace,"lock") throw ##class(%Exception.General).%New("BUSY") }
    try {
        if '$data(^PIData($namespace,"notification",id)) { throw ##class(%Exception.General).%New("NOT_FOUND") }
        set n={}.%FromJSON(^PIData($namespace,"notification",id))
        if (n.%Get("simulated",1)=0)&&(n.status="FAILED") {
            set n.status="PENDING",n.nextAttemptAt=0,n.cycleAttempts=0
            tstart
            set ^PIData($namespace,"notification",id)=n.%ToJSON()
            set ^PIData($namespace,"notificationPending",n.sequence)=id
            do ##class(PI.Store).Audit(n.caseId,"NOTIFICATION_REOPENED",id)
            tcommit
        }
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"notifyLock",id)
        lock -^PIData($namespace,"lock")
        throw ex
    }
    lock -^PIData($namespace,"notifyLock",id)
    lock -^PIData($namespace,"lock")
}
}
