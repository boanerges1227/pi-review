Class PI.Process Extends Ens.BusinessProcess
{
/// Orchestrate source ingestion and real Agent investigations, routing each decision to its business operation.
Method OnRequest(request As PI.Message, Output response As PI.Reply) As %Status
{
    set response=##class(PI.Reply).%New()
    try {
        set input={}.%FromJSON(request.Payload)
        if input.%Get("resourceType","")="Bundle" {
            set result=##class(PI.FHIR.Message).Process(input)
        } elseif input.%Get("action","")="investigate" {
            set id=input.caseId,d=##class(PI.Agent).Investigate(id)
            set route=$select(d.decision="LINK_REVIEW":"LinkReview",d.decision="SEPARATE_REVIEW":"SeparateReview",d.decision="NEEDS_DATA":"Enrichment",1:"ConflictReview")
            set message=##class(PI.Message).%New(),message.Payload={"caseId":(id),"result":(d)}.%ToJSON()
            set sc=..SendRequestSync(route,message,.reply)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            set result={}.%FromJSON(reply.Payload)
        } elseif input.%Get("action","")="fetch-enrichment" {
            set result=##class(PI.MCP.Enrichment).Fetch(input.caseId,input.version)
        } else {
            set result=##class(PI.Store).Ingest(input)
        }
    } catch ex { set result={"code":(ex.Name)} }
    set response.Payload=result.%ToJSON()
    quit 1
}
}
