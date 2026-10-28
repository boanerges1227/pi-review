Class PI.Service Extends Ens.BusinessService
{
Parameter ADAPTER = "";
/// Synchronously deliver through the real interoperability message chain instead of bypassing Production to call business classes.
Method Submit(input As %DynamicObject, Output result As %DynamicObject) As %Status
{
    set req=##class(PI.Message).%New(),req.Payload=input.%ToJSON()
    set sc=..SendRequestSync("IdentityProcess",req,.reply,140)
    if $system.Status.IsOK(sc) { set result={}.%FromJSON(reply.Payload) }
    quit sc
}
}
