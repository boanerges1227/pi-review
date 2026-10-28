Class PI.MCPDashboardTests Extends %RegisteredObject
{
/// Seed isolated telemetry with distinct transport, verification, and task outcomes.
ClassMethod Seed()
{
    do ##class(PI.Tests).Reset()
    kill ^PIMCPAccess($namespace,"audit")
    set a=##class(PI.Store).Ingest(##class(PI.Tests).Input()),b=##class(PI.Tests).Input("EMR","dashboard"),x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set c.version=2,c.status="NEEDS_DATA",c.enrichmentVersion=2,^PIData($namespace,"case",c.id)=c.%ToJSON()
    for i=1:1:3 {
        set tool=$piece("verify_source_record,request_enrichment,get_enrichment",",",i),outcome=$select(i=2:"FAILED",1:"OK"),seconds=$select(i=1:.01,i=2:.2,1:.03)
        set ^PIData($namespace,"mcpTrace",c.id,i)={"callId":(i),"caseId":(c.id),"caseVersion":2,"runId":7,"tool":(tool),"outcome":(outcome),"elapsedSeconds":(seconds),"authorization":"DO_NOT_PUBLISH","toolref":"DO_NOT_PUBLISH"}.%ToJSON()
    }
    set ^PIData($namespace,"evidence",c.id,2,"e1")={"tool":"verify_source_identity","data":{"status":"VERIFIED","secret":"DO_NOT_PUBLISH"}}.%ToJSON()
    set ^PIData($namespace,"evidence",c.id,2,"e2")={"tool":"verify_source_identity","data":{"status":"MISMATCH"}}.%ToJSON()
    set ^PIData($namespace,"enrichment",c.id,1)={"caseId":(c.id),"status":"APPLIED","transport":"mcp","waitingVersion":1}.%ToJSON()
    set ^PIData($namespace,"enrichment",c.id,2)={"caseId":(c.id),"status":"READY","transport":"mcp","originVersion":1,"waitingVersion":2,"missingFields":["identifier"],"requestId":"task-2","secret":"DO_NOT_PUBLISH"}.%ToJSON()
    set ^PIData($namespace,"enrichment",c.id,3)={"caseId":(c.id),"status":"READY","transport":"mcp","waitingVersion":3}.%ToJSON()
    set ^PIMCPAccess($namespace,"audit",1)={"actor":"local-reviewer","tool":"review_case","outcome":"ALLOWED","durationMs":4,"time":"2026-10-27 07:00:00","token":"DO_NOT_PUBLISH"}.%ToJSON()
    set ^PIMCPAccess($namespace,"audit",2)={"actor":"local-reviewer","tool":"review_case","outcome":"DENIED","durationMs":0}.%ToJSON()
}

/// Assert real aggregation and sensitive-field exclusion rather than implementation text.
ClassMethod Metrics()
{
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.MCP.Dashboard||Snapshot"),"MCP dashboard backend must exist")
    do ..Seed()
    set d=##class(PI.MCP.Dashboard).Snapshot()
    do ##class(PI.Tests).Assert(d.namespace="PITEST","namespace is server selected")
    do ##class(PI.Tests).Assert((d.summary.outbound.total=3)&&(d.summary.outbound.ok=2)&&(d.summary.outbound.failed=1),"transport outcomes counted independently")
    do ##class(PI.Tests).Assert((d.summary.outbound.averageMs=80)&&(d.summary.outbound.p95Ms=200),"end-to-end latency uses all actual samples")
    do ##class(PI.Tests).Assert((d.summary.verifications.verified=1)&&(d.summary.verifications.mismatch=1),"business evidence is separate from transport success")
    do ##class(PI.Tests).Assert((d.summary.published.allowed=1)&&(d.summary.published.denied=1),"published authorization outcomes are counted")
    do ##class(PI.Tests).Assert((d.summary.enrichment.active=1)&&(d.summary.enrichment.total=3),"only the current waiting task counts active")
    do ##class(PI.Tests).Assert($find(d.%ToJSON(),"DO_NOT_PUBLISH")=0,"raw extensions and credentials must be excluded")
    do ##class(PI.Tests).Assert(d.events.%Get(0).timestampKnown=0,"missing legacy times cannot become current timestamps")
    set limited=##class(PI.MCP.Dashboard).Snapshot(2)
    do ##class(PI.Tests).Assert(limited.scan.truncated.outbound&&(limited.summary.outbound.total=2),"bounded metrics disclose partial scans")
    write "MCP_DASHBOARD_METRICS_OK",!
}

/// The most recent call can belong to an older case; case-order traversal must not decide recency.
ClassMethod Latest()
{
    do ..Seed()
    for i=4:1:108 {
        set id=$select(i#2:"c1",1:"c99")
        set ^PIData($namespace,"mcpTrace",id,i)={"callId":(i),"caseId":(id),"caseVersion":2,"tool":"verify_source_record","outcome":"OK","elapsedSeconds":0.01,"occurredAtEpoch":(1000+i)}.%ToJSON()
    }
    set d=##class(PI.MCP.Dashboard).Snapshot(),outbound=[]
    for i=0:1:d.events.%Size()-1 { set event=d.events.%Get(i) if event.direction="outbound" { do outbound.%Push(event) } }
    do ##class(PI.Tests).Assert(outbound.%Size()=100,"outbound activity is bounded")
    do ##class(PI.Tests).Assert(outbound.%Get(0).eventId=108,"latest event is selected globally across cases")
    do ##class(PI.Tests).Assert(outbound.%Get(99).eventId=9,"oldest records leave the latest activity window")
    write "MCP_DASHBOARD_LATEST_OK",!
}
/// Timestamp only new producer events and retain requested case context in publishing audit.
ClassMethod Timestamps()
{
    do ..Seed()
    set before=##class(PI.MCP.Dashboard).Now(),c=##class(PI.Store).Case("c1")
    do ##class(PI.MCP.Client).Trace(c,9,999,"verify_source_record","OK",.025)
    set event={}.%FromJSON(^PIData($namespace,"mcpTrace","c1",999))
    do ##class(PI.Tests).Assert(event.%Get("occurredAtEpoch",0)>=before,"new source calls carry actual observation timestamps")
    do ##class(PI.MCP.ReadAudit).Record("review_case","ALLOWED",3,"c1",2)
    set id=$get(^PIMCPAccess($namespace,"auditSeq")),event={}.%FromJSON(^PIMCPAccess($namespace,"audit",id))
    do ##class(PI.Tests).Assert((event.%Get("caseId","")="c1")&&(event.%Get("caseVersion",0)=2),"publishing audit records only scoped case/version fields")
    do ##class(PI.Tests).Assert(event.%Get("occurredAtEpoch",0)>=before,"new publishing audits carry actual observation timestamps")
    write "MCP_DASHBOARD_TIMESTAMPS_OK",!
}
/// Native build154 audit callbacks serialize arguments even though authorization callbacks use objects.
ClassMethod AuditCallback()
{
    set args={"caseId":"c1","expectedVersion":2},call={"name":"review_case","arguments":(args.%ToJSON())},audit=##class(PI.MCP.ReadAudit).%New()
    set before=+$get(^PIMCPAccess($namespace,"auditSeq")),sc=audit.%LogExecution(call,{}, {},4,1)
    set id=+$get(^PIMCPAccess($namespace,"auditSeq"))
    do ##class(PI.Tests).Assert((id=before+1)&&$system.Status.IsOK(sc),"actual audit callback shape records a completed invocation")
    set event={}.%FromJSON(^PIMCPAccess($namespace,"audit",id))
    do ##class(PI.Tests).Assert((event.caseId="c1")&&(event.caseVersion=2)&&event.%IsDefined("occurredAtEpoch"),"serialized arguments retain safe correlation and actual time")
    set call.arguments="invalid JSON",sc=audit.%LogExecution(call,{}, {},4,1),id=+$get(^PIMCPAccess($namespace,"auditSeq")),event={}.%FromJSON(^PIMCPAccess($namespace,"audit",id))
    do ##class(PI.Tests).Assert((event.caseId="")&&(event.tool="review_case"),"malformed arguments cannot suppress the audit or leak raw text")
    set policy=##class(PI.MCP.ReadPolicy).%New(),call={"name":"review_case","arguments":"invalid JSON"},sc=policy.%CanExecute("review_case",call,{"origin_class":"PI.MCP.ReadTools"})
    do ##class(PI.Tests).Assert($system.Status.IsError(sc),"malformed policy arguments are denied without suppressing audit")
    write "MCP_DASHBOARD_AUDIT_CALLBACK_OK",!
}
/// A slower low-ID call can finish last; completion time determines the latest observation.
ClassMethod CompletionOrder()
{
    do ..Seed()
    set ^PIData($namespace,"mcpTrace","c1",4)={"callId":4,"caseId":"c1","caseVersion":2,"tool":"verify_source_record","outcome":"FAILED","elapsedSeconds":1,"occurredAtEpoch":5000}.%ToJSON()
    for i=5:1:108 {
        set ^PIData($namespace,"mcpTrace","c99",i)={"callId":(i),"caseId":"c99","caseVersion":2,"tool":"verify_source_record","outcome":"OK","elapsedSeconds":0.01,"occurredAtEpoch":(1000+i)}.%ToJSON()
    }
    set d=##class(PI.MCP.Dashboard).Snapshot(),observation=d.servers.%Get(0).observation
    do ##class(PI.Tests).Assert((observation.eventId=4)&&(observation.outcome="FAILED"),"latest service observation follows completion time instead of start ID")
    do ##class(PI.Tests).Assert(d.events.%Get(0).eventId=4,"latest low-ID completion survives the bounded event window")
    write "MCP_DASHBOARD_COMPLETION_ORDER_OK",!
}
}
