Class PI.Notification.Operation Extends Ens.BusinessOperation
{
Parameter ADAPTER = "PI.Adapter.IdentityResultOutbound";
Parameter INVOCATION = "Queue";
Parameter SETTINGS = "MaxAttempts,RetrySeconds";

Property MaxAttempts As %Integer(MINVAL = 1, MAXVAL = 20) [ InitialExpression = 3 ];
Property RetrySeconds As %Integer(MINVAL = 1, MAXVAL = 3600) [ InitialExpression = 5 ];

/// Serialize duplicate queue entries per event without holding any patient review transaction lock.
Method OnMessage(request As PI.Notification.Request, Output response As Ens.Response) As %Status
{
    set id=request.NotificationId,response=##class(Ens.Response).%New()
    lock +^PIData($namespace,"notifyLock",id):1
    if '$test { quit 1 }
    try {
        if $data(^PIData($namespace,"notification",id)) {
            set n={}.%FromJSON(^PIData($namespace,"notification",id))
            if (n.%Get("simulated",1)=0)&&(n.status="QUEUED") {
                // A crash after the last persisted attempt must not create an unbounded extra retry budget.
                if n.cycleAttempts>=..MaxAttempts {
                    set n.status="FAILED",n.lastError="HIS_ATTEMPTS_EXHAUSTED"
                } else {
                    // Persist the attempt before network I/O so an interrupted worker leaves recoverable state.
                    set n.attempts=n.attempts+1,n.cycleAttempts=n.cycleAttempts+1
                    set ^PIData($namespace,"notification",id)=n.%ToJSON()
                    set sc=..Adapter.SendResult(n.payload,.receipt)
                    if $system.Status.IsOK(sc) {
                        set n.status="SENT",n.receipt=receipt,n.sentAt=##class(PI.Notification.Outbox).Now(),n.lastError=""
                    } else {
                        set n.status=$select(n.cycleAttempts>=..MaxAttempts:"FAILED",1:"RETRY")
                        set n.nextAttemptAt=##class(PI.Notification.Outbox).Now()+..RetrySeconds,n.lastError="HIS_DELIVERY_FAILED"
                    }
                }
                // Save state and audit together; an interrupted commit safely replays the same external event.
                tstart
                set ^PIData($namespace,"notification",id)=n.%ToJSON()
                if (n.status="SENT")!(n.status="FAILED") { kill ^PIData($namespace,"notificationPending",n.sequence) }
                do ##class(PI.Store).Audit(n.caseId,"NOTIFICATION_"_n.status,id)
                tcommit
            }
        }
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"notifyLock",id)
        return ex.AsStatus()
    }
    lock -^PIData($namespace,"notifyLock",id)
    quit 1
}
}
