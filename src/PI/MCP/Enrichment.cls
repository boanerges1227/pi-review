Class PI.MCP.Enrichment Extends %RegisteredObject
{
/// Fetch a task outside the business lock; only the final guarded write may advance a case.
ClassMethod Fetch(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set c=##class(PI.Store).Case(caseId)
    if c.version'=expectedVersion { throw ##class(%Exception.General).%New("STALE_CASE") }
    if c.status'="NEEDS_DATA" { throw ##class(%Exception.General).%New("ENRICHMENT_NOT_WAITING") }
    set task={}.%FromJSON(^PIData($namespace,"enrichment",caseId,c.enrichmentVersion))
    set data=##class(PI.MCP.Client).Call(c,c.incoming,"get_enrichment",task)
    if data.status'="READY" { quit {"caseId":(caseId),"status":"WAITING","transport":"mcp"} }
    quit ..ApplyUpdate(caseId,expectedVersion,task,data)
}

/// Keep the final snapshot guard and ingestion under the same reentrant lock as human approval.
ClassMethod ApplyUpdate(caseId As %String, expectedVersion As %Integer, task As %DynamicObject, data As %DynamicObject) As %DynamicObject
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=##class(PI.Store).Case(caseId)
        if c.version'=expectedVersion { throw ##class(%Exception.General).%New("STALE_CASE") }
        if c.status'="NEEDS_DATA" { throw ##class(%Exception.General).%New("CASE_CLOSED") }
        set saved={}.%FromJSON(^PIData($namespace,"enrichment",caseId,c.enrichmentVersion))
        if (saved.requestId'=task.%Get("requestId",""))!(saved.waitingVersion'=expectedVersion) { throw ##class(%Exception.General).%New("SOURCE_REQUEST_MISMATCH") }
        if (data.%Get("namespace","")'=$namespace)!(data.%Get("caseId","")'=caseId)!(data.%Get("caseVersion",0)'=expectedVersion)!(data.%Get("requestId","")'=saved.requestId) { throw ##class(%Exception.General).%New("SOURCE_SCOPE_MISMATCH") }
        set record=data.%Get("record",{})
        if (record.%Get("sourceSystem","")'=c.incoming.sourceSystem)!(record.%Get("sourcePatientId","")'=c.incoming.sourcePatientId)!(record.%Get("sourceVersion",0)<=c.incoming.sourceVersion) { throw ##class(%Exception.General).%New("SOURCE_RECORD_MISMATCH") }
        set result=##class(PI.Store).Ingest(record)
        set saved.status="APPLIED",saved.appliedSourceVersion=record.sourceVersion,saved.receiptId=data.receiptId
        set ^PIData($namespace,"enrichment",caseId,c.enrichmentVersion)=saved.%ToJSON()
        do ##class(PI.Store).Audit(caseId,"MCP_ENRICHMENT_APPLIED",saved.requestId)
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit result
}
}
