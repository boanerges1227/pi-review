Class PI.Notification.Relay Extends Ens.BusinessService
{
Parameter ADAPTER = "Ens.InboundAdapter";

/// Poll a bounded, rotating slice of the durable outbox using the native adapter's CallInterval.
Method OnProcessInput(input As %RegisteredObject, Output output As %RegisteredObject) As %Status
{
    set cursor=$get(^PIData($namespace,"notificationCursor")),count=0
    while count<100 {
        set cursor=$order(^PIData($namespace,"notificationPending",cursor))
        quit:cursor=""
        set count=count+1,id=$get(^PIData($namespace,"notificationPending",cursor))
        continue:id=""
        if ##class(PI.Notification.Outbox).Claim(id) {
            set req=##class(PI.Notification.Request).%New(),req.NotificationId=id
            set sc=..SendRequestAsync("IdentityResultOutbound",req)
            if $system.Status.IsError(sc) { do ##class(PI.Notification.Outbox).QueueFailed(id) }
        }
    }
    set ^PIData($namespace,"notificationCursor")=cursor
    quit 1
}
}
