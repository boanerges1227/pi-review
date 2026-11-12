Class PI.TraceTests Extends %RegisteredObject
{
/// Require the telemetry schema before testing real SDK/Production paths.
ClassMethod Schema()
{
    if '##class(%Dictionary.CompiledClass).%ExistsId("PI.Trace.Event") { throw ##class(%Exception.General).%New("TRACE689_IMPLEMENTATION_MISSING") }
    set event=##class(PI.Trace.Event).%New(),event.TraceId="synthetic-trace",event.Kind="run.start",event.Status="RUNNING",event.Coverage="pending",event.Sequence=1,event.Fallback="none"
    do event.Validate()
    set denied=0
    try { set event.Kind="private prompt sentinel" do event.Validate() } catch ex { set denied=1 }
    if 'denied { throw ##class(%Exception.General).%New("TRACE689_UNBOUNDED_KIND") }
    set cls=##class(%Dictionary.ClassDefinition).%OpenId("PI.Trace.Event")
    for i=1:1:cls.Properties.Count() { set p=cls.Properties.GetAt(i) if (p.Name="Payload")!(p.Name="Prompt")!(p.Name="ApiKey") { throw ##class(%Exception.General).%New("TRACE689_PRIVATE_FIELD") } }
    write "TRACE689_SCHEMA_OK",!
}

/// Drive the actual investigation worker and existing JSON repair with a local non-JSON transport fixture.
ClassMethod RepairWorker()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    do ##class(PI.Tests).Reset()
    set seeded=##class(PI.Fixtures).Seed(),c=seeded.cases.%Get(0),name=##class(PI.ModelConfig).BaseName()
    set sc=##class(%ConfigStore.Configuration).Get(name,.cfg)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("TEST_CONFIG_MISSING") }
    set original=cfg.Details.%ToJSON(),oldActive=$get(^PIModels($namespace,"active")),captured=""
    kill ^PIModels($namespace,"active")
    try {
        set d={"model_provider":"openai","model":"fixture-repair","base_url":"http://127.0.0.1:18541/v1/","api_key":"unused"}
        set sc=##class(%ConfigStore.Configuration).Modify(name,d,cfg.DisplayName,cfg.Description,cfg.ReadResource,cfg.EditResource,1)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set run=$increment(^PIData($namespace,"seq","run"))
        do ##class(PI.Agent).Worker(c.id,run)
        set record={}.%FromJSON(^PIData($namespace,"run",c.id,run))
        if 'record.modelStarted { throw ##class(%Exception.General).%New("REPAIR_MODEL_NOT_STARTED") }
        set query="SELECT Kind,SpanId,Status,PromptVersion,RetryKind,ErrorCode FROM PI_Trace.Event WHERE TraceId=? ORDER BY Sequence",rs=##class(%SQL.Statement).%ExecDirect(,query,record.traceId),requests=0,ends=0,repairs=0,invalid=0
        while rs.%Next() {
            if rs.%Get("Kind")="model.request" { set requests=requests+1 if rs.%Get("RetryKind")="application-json-repair" { set repairs=repairs+1 } }
            if rs.%Get("Kind")="sdk.end" { set ends=ends+1 if rs.%Get("Status")'="SUCCEEDED" { throw ##class(%Exception.General).%New("HTTP_SUCCESS_MISLABELED") } }
            if rs.%Get("ErrorCode")="INVALID_MODEL_JSON" { set invalid=invalid+1 }
        }
        if (requests'=2)!(ends'=2)!(repairs'=1)!(invalid<1) { throw ##class(%Exception.General).%New("REPAIR_TRACE_INVALID") }
        if $data(^PIData($namespace,"traceWork",run))!$data(^PIData($namespace,"traceRun",c.id,run)) { throw ##class(%Exception.General).%New("PRIVATE_CANDIDATE_LEAK") }
    } catch ex { set captured=ex }
    set restored={}.%FromJSON(original),sc=##class(%ConfigStore.Configuration).Modify(name,restored,cfg.DisplayName,cfg.Description,cfg.ReadResource,cfg.EditResource,1)
    if oldActive'="" { set ^PIModels($namespace,"active")=oldActive }
    if $isobject(captured) { throw captured }
    write "TRACE689_REPAIR_WORKER_OK",!
}
}
