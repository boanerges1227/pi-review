Class PI.Adapter.IdentityResultOutbound Extends EnsLib.HTTP.OutboundAdapter
{
Property WriteTimeout As %Numeric [ InitialExpression = 5 ];

/// Send an immutable identity-result event and accept only a receipt for that exact event.
Method SendResult(payload As %DynamicObject, Output receipt As %DynamicObject) As %Status
{
    try {
        if (..HTTPServer="")!(..URL="") { throw ##class(%Exception.General).%New("HIS_ENDPOINT_REQUIRED") }
        if (..ConnectTimeout<1)!(..ResponseTimeout<1)!(..WriteTimeout<1)!(..ConnectTimeout+..ResponseTimeout+..WriteTimeout>45) { throw ##class(%Exception.General).%New("HIS_TIMEOUT_INVALID") }
        set http=##class(%Net.HttpRequest).%New(),http.ContentType="application/json",http.FollowRedirect=0
        do http.SetHeader("Idempotency-Key",payload.eventId)
        do http.SetHeader("Accept","application/json")
        set data(1)=payload.%ToJSON()
        set sc=..SendFormDataArray(.response,"POST",http,"",.data)
        // Native HTTP retry flags must not bypass the durable outbox's bounded retry policy.
        set ..BusinessHost.Retry=0
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("HIS_TRANSPORT_FAILED") }
        if '$isobject(response) { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if (response.StatusCode'=200)&&(response.StatusCode'=201) { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if response.Data.Size>8192 { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        try { set receipt={}.%FromJSON(response.Data) } catch parse { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if 'receipt.%IsA("%DynamicObject") { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if (receipt.%GetTypeOf("eventId")'="string")!(receipt.%Get("eventId","")'=payload.eventId) { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if (receipt.%Get("status","")'="ACCEPTED")&&(receipt.%Get("status","")'="DUPLICATE") { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        if (receipt.%GetTypeOf("receiptId")'="string")!($length(receipt.%Get("receiptId",""))<1)!($length(receipt.receiptId)>200) { throw ##class(%Exception.General).%New("HIS_RECEIPT_INVALID") }
        // Persist only the protocol fields, never arbitrary data returned by the remote endpoint.
        set receipt={"eventId":(receipt.eventId),"status":(receipt.status),"receiptId":(receipt.receiptId)}
    } catch ex {
        set ..BusinessHost.Retry=0
        return ex.AsStatus()
    }
    quit 1
}
}
