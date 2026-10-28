Class PI.Phase1 Extends PI.Tests
{
/// Read configuration from native Config Store and store keys only in Wallet.
ClassMethod Configuration()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.ModelConfig"),"phase1 native configuration adapter exists")
    do ##class(PI.ModelConfig).Install("synthetic-not-a-real-key","https://example.invalid/v1","synthetic-model")
    set props=##class(PI.ModelConfig).Resolve(),safe=##class(PI.ModelConfig).Public()
    set provider=##class(PI.ModelConfig).Provider(.model)
    do ..Assert($isobject(provider)&&(model="synthetic-model"),"native provider accepts configured HTTP timeouts without network")
    do ..Assert(props.%Get("api_key")="synthetic-not-a-real-key","wallet reference resolves without network")
    do ..Assert(safe.configName="AI.LLM.PIReviewPITEST","configuration isolated by namespace")
    do ..Assert(safe.%ToJSON()'["synthetic-not-a-real-key","public configuration does not disclose key")
    new $namespace
    set $namespace="%SYS",sc=##class(%ConfigStore.Configuration).Get("AI.LLM.PIReviewPITEST",.cfg)
    do ..Assert($system.Status.IsOK(sc),"native config retrievable")
    do ..Assert(cfg.Details.%Get("api_key")="secret://PIReviewPITEST.Model#api_key","stored config contains reference only")
    write "PHASE1_CONFIG_OK",!
}
/// Use the real ToolManager to verify denials produce no evidence and trigger native auditing.
ClassMethod NativePolicies()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.Authorization"),"native authorization class exists")
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),b=..Input("EMR","policy")
    set x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set ^PIData($namespace,"context",$job,"runId")=1001
    set p=##class(%AI.Provider).Create("openai",{"api_key":"unused"}),agent=##class(%AI.Agent).%New(p)
    do agent.UseToolSet("PI.Tools")
    do agent.ToolManager.SetAuthPolicy(##class(PI.Authorization).%New())
    do agent.ToolManager.SetAuditPolicy(##class(PI.ToolAudit).%New())
    set allowed=agent.ToolManager.ExecuteTool("get_case_summary",{})
    do ..Assert($get(^PIData($namespace,"context",$job,"calls"))=1,"allowed SDK tool actually executed")
    set before=$get(^PIData($namespace,"seq","evidence")),denied=0
    try { set result=agent.ToolManager.ExecuteTool("get_candidate_profile",{"candidateId":"r99999"}) } catch ex { set denied=1 }
    do ..Assert($get(^PIData($namespace,"seq","evidence"))=before,"denied SDK tool cannot create evidence")
    set traces=##class(PI.ToolAudit).List(c.id),ok=0,no=0
    for i=0:1:traces.%Size()-1 { set t=traces.%Get(i) if t.outcome="ALLOWED" { set ok=1 } if t.outcome="DENIED" { set no=1 } }
    do ..Assert(ok&&no,"native execution success and authorization denial are both audited")
    do ##class(PI.Tools).End()
    write "PHASE1_POLICIES_OK",!
}
/// Real native retrieval must return current-version rules rather than manually fabricated search results.
ClassMethod Governance()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.Governance"),"native governance RAG exists")
    do ##class(PI.Governance).Install("test-v1")
    set result=##class(PI.Governance).Search("Different identifiers prohibit linking patients")
    do ..Assert(result.chunks.%Size()>0,"native vector search returns actual chunks")
    do ..Assert(result.version="test-v1","rule evidence carries current version")
    do ##class(PI.Governance).Install("test-v2")
    set result=##class(PI.Governance).Search("Missing date of birth and identifier need enrichment")
    do ..Assert(result.version="test-v2","updated native index returns new rule version")
    do ..Assert(result.chunks.%ToJSON()'["test-v1","obsolete rule version excluded")
    write "PHASE1_GOVERNANCE_OK",!
}

/// Native Session persistence, case version changes, and usage deltas must work without retaining live objects.
ClassMethod Sessions()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.Sessions"),"native persistent sessions adapter exists")
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),b=..Input("EMR","session")
    set x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set p=##class(%AI.Provider).Create("openai",{"api_key":"unused"}),agent=##class(%AI.Agent).%New(p)
    set session=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
    do session.InsertMessage(0,{"role":"user","content":"synthetic session persistence"})
    do ##class(PI.Sessions).Save(c,session)
    set savedId=session.%Id(),session="",agent="",p=""
    set p=##class(%AI.Provider).Create("openai",{"api_key":"unused"}),agent=##class(%AI.Agent).%New(p)
    set restored=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
    do ..Assert(resumed&&(restored.%Id()=savedId),"native saved session restored in new agent")
    do ..Assert(restored.MessageCount()>0,"native persisted context restored")
    set c.version=c.version+1,^PIData($namespace,"case",c.id)=c.%ToJSON(),restored="",agent=""
    set agent=##class(%AI.Agent).%New(p),restored=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
    do ..Assert(reset&&(restored.MessageCount()=0),"changed version clears obsolete facts while retaining native session")
    set delta=##class(PI.Sessions).Delta({"total_prompt_tokens":100,"total_completion_tokens":20},{"total_prompt_tokens":160,"total_completion_tokens":25})
    do ..Assert((delta.%Get("total_prompt_tokens")=60)&&(delta.%Get("total_completion_tokens")=5),"billing uses new tokens only")
    write "PHASE1_SESSIONS_OK",!
}
/// Reject concurrent investigations of the same case before reserving budget or starting a model process.
ClassMethod ConcurrentInvestigation()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),x=##class(PI.Store).Ingest(..Input("EMR","busy"))
    kill ^PITestSync
    job ..HoldInvestigation(x.caseId)
    set pid=$zchild,start=$zh
    for { quit:$data(^PITestSync("ready"))  quit:($zh-start)>3  hang 0.05 }
    if '$data(^PITestSync("ready")) { throw ##class(%Exception.General).%New("TEST_LOCK_SETUP_FAILED") }
    set before=$get(^PIBudget($namespace,"seq")),result=##class(PI.Agent).Investigate(x.caseId)
    set ^PITestSync("release")=1
    do ..Assert(result.%Get("error","")="CASE_BUSY","overlapping same-case investigation denied before live call")
    do ..Assert($get(^PIBudget($namespace,"seq"))=before,"busy case reserves no model budget")
    write "PHASE1_CONCURRENCY_OK",!
}

/// Hold a short-lived lock only in the test namespace to reproduce a second process contending for the same case.
ClassMethod HoldInvestigation(caseId As %String)
{
    lock +^PIRunLock($namespace,caseId):1
    set ^PITestSync("ready")=1,start=$zh
    for { quit:$data(^PITestSync("release"))  quit:($zh-start)>4  hang 0.05 }
    lock -^PIRunLock($namespace,caseId)
}
/// After conservative settlement of an old timeout, reserve all remaining authorization without resetting cumulative accounting.
ClassMethod BudgetHeadroom()
{
    kill ^PIBudget($namespace)
    set ^PIBudget($namespace,"spentCny")=18
    set id=##class(PI.Agent).ReserveAvailable()
    do ..Assert(^PIBudget($namespace,"reservedCny")=12,"reserve only remaining authorized headroom")
    do ##class(PI.Agent).Settle(id,{})
    do ..Assert((^PIBudget($namespace,"spentCny")=30)&&(^PIBudget($namespace,"reservedCny")=0),"unknown usage consumes exactly its reservation")
    do ..Assert($get(^PIBudget($namespace,"unknownCny"))=12,"unknown usage allowance is distinct from known token estimate")
    set denied=0
    try { set id=##class(PI.Agent).ReserveAvailable() } catch ex { set denied=(ex.Name="BUDGET_LIMIT") }
    do ..Assert(denied,"exhausted authorized budget blocks further calls")
    kill ^PIBudget($namespace)
    write "PHASE1_HEADROOM_OK",!
}
/// Release the reservation for local failures before a model request; distinguish these from post-request failures with unknown usage.
ClassMethod LocalFailureBilling()
{
    do ..Reset()
    kill ^PIBudget($namespace)
    set id=##class(PI.Agent).Reserve()
    do ##class(PI.Agent).Worker("missing-local-case",9001)
    set r={}.%FromJSON(^PIData($namespace,"run","missing-local-case",9001))
    do ..Assert(r.%Get("modelStarted",-1)=0,"pre-request local error identified explicitly")
    do ##class(PI.Agent).Settle(id,r.billingStats)
    do ..Assert((^PIBudget($namespace,"spentCny")=0)&&(^PIBudget($namespace,"reservedCny")=0),"local pre-request failure consumes no model budget")
    kill ^PIBudget($namespace)
    write "PHASE1_LOCAL_FAILURE_OK",!
}
/// Native policy must reject external tool registrations with the same name; policy citations must be real evidence from the current index.
ClassMethod PolicyBoundaries()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),x=##class(PI.Store).Ingest(..Input("EMR","citation")),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set policy=##class(PI.Authorization).%New(),sc=policy.%CanExecute("get_case_summary",{"name":"get_case_summary","arguments":{}},{"origin_class":"Other.Tools"})
    do ..Assert($system.Status.IsError(sc),"same-name foreign registration cannot bypass native policy")
    set comparison=##class(PI.Tools).Compare("r"_a.recordId)
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"LINK_REVIEW","candidateId":("r"_a.recordId),"evidenceIds":[(comparison.evidenceId)],"conflicts":[],"missingFields":[],"reasonSummary":"Synthetic evidence"}
    set result=##class(PI.Policy).Validate(c.id,d,1)
    do ..Assert(result.error="CURRENT_GOVERNANCE_REQUIRED","comparison alone cannot replace required current governance citation")
    set g=##class(PI.Tools).SearchGovernance("Identity identifiers and human approval"),d.evidenceIds=[(comparison.evidenceId),(g.evidenceId)]
    set result=##class(PI.Policy).Validate(c.id,d,1)
    do ..Assert(result.decision="LINK_REVIEW","native current governance evidence accepted")
    do ##class(PI.Governance).Install("test-v3")
    set result=##class(PI.Policy).Validate(c.id,d,1)
    do ..Assert(result.error="CURRENT_GOVERNANCE_REQUIRED","obsolete real rule evidence rejected after reindex")
    set old=c.%ToJSON(),c.version=c.version+1,^PIData($namespace,"case",c.id)=c.%ToJSON()
    set sc=policy.%CanExecute("get_case_summary",{"name":"get_case_summary","arguments":{}},{"origin_class":"PI.Tools"})
    do ..Assert($system.Status.IsError(sc),"native authorization rejects case updated during investigation")
    do ##class(PI.Tools).End()
    write "PHASE1_BOUNDARIES_OK",!
}
/// Update restored native execution configuration with the server's model and prompt, not just outer Agent labels.
ClassMethod RestoredConfiguration()
{
    do ..Reset()
    set x=##class(PI.Store).Ingest(..Input("CHECKUP","model-switch")),b=..Input("EMR","model-switch"),b.identifier="SYN-9999",y=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(y.caseId)
    set p=##class(%AI.Provider).Create("openai",{"api_key":"unused","base_url":"http://127.0.0.1:18541/v1"}),agent=##class(%AI.Agent).%New(p),agent.Model="model-a",agent.SystemPrompt="Synthetic prompt A"
    set session=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
    set initial=agent.Chat(session,"Synthetic initial turn for cumulative statistics")
    do ##class(PI.Sessions).Save(c,session)
    set session="",agent="",agent=##class(%AI.Agent).%New(p),agent.Model="model-b",agent.SystemPrompt="Synthetic prompt B"
    set session=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
    do ..Assert(session.GetStats().%Get("total_prompt_tokens")=100,"native cumulative usage survives model and prompt reset")
    set response=agent.Chat(session,"Synthetic transport configuration test only")
    do ..Assert(session.GetStats().%Get("total_prompt_tokens")=200,"restored native usage accumulates rather than resetting")
    set stream=##class(%Stream.FileCharacter).%New(),stream.Filename="/tmp/pi-synthetic-provider.capture.json",actual={}.%FromJSON(stream)
    do ..Assert(actual.%Get("model","")="model-b","actual native HTTP request uses new model")
    do ..Assert(actual.systemPrompts.%ToJSON()["Synthetic prompt B","actual native HTTP request uses new system prompt")
    do ..Assert(actual.systemPrompts.%ToJSON()'["Synthetic prompt A","old persisted prompt is removed from actual request")
    write "PHASE1_MODEL_SWITCH_OK",!
}

/// Connect to a closed local port to reproduce native request failure without paid model calls; the first failure must remain recoverable.
ClassMethod FailureCheckpoint()
{
    do ..Reset()
    do ..TestEndpoint("http://127.0.0.1:1/v1")
    try {
        set a=##class(PI.Store).Ingest(..Input()),x=##class(PI.Store).Ingest(..Input("EMR","failure-checkpoint")),c=##class(PI.Store).Case(x.caseId)
        do ##class(PI.Agent).Worker(c.id,9201)
        set saved=$get(^PIData($namespace,"session",c.id,"id"))
        do ..Assert(saved'="","first failed native Chat retains a durable SDK session mapping")
        set p=##class(%AI.Provider).Create("openai",{"api_key":"unused"}),agent=##class(%AI.Agent).%New(p),agent.Model="synthetic-model"
        set session=##class(PI.Sessions).Open(agent,c,.resumed,.reset)
        do ..Assert(resumed&&(session.%Id()=saved),"failed turn restores same native session")
        set run={}.%FromJSON(^PIData($namespace,"run",c.id,9201))
        do ..Assert(run.modelStarted&&(run.sdkSessionId=saved),"failure trace identifies attempted call and checkpoint session")
    } catch ex { do ..TestEndpoint("https://example.invalid/v1") throw ex }
    do ..TestEndpoint("https://example.invalid/v1")
    write "PHASE1_FAILURE_CHECKPOINT_OK",!
}

/// Change only the endpoint of synthetic PITEST configurations; never touch real USER Wallet or model configuration.
ClassMethod TestEndpoint(url As %String)
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    new $namespace
    set $namespace="%SYS",sc=##class(%ConfigStore.Configuration).Get("AI.LLM.PIReviewPITEST",.cfg)
    set cfg.Details."base_url"=url,sc=cfg.%Save()
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}

/// Even when the case version is unchanged, prior-round evidence cannot serve as newly gathered evidence for this round.
ClassMethod RunEvidence()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),x=##class(PI.Store).Ingest(..Input("EMR","run-evidence")),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set ^PIData($namespace,"context",$job,"runId")=9301
    set comparison=##class(PI.Tools).Compare("r"_a.recordId),governance=##class(PI.Tools).SearchGovernance("Identity identifiers and human approval")
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"LINK_REVIEW","candidateId":("r"_a.recordId),"evidenceIds":[(comparison.evidenceId),(governance.evidenceId)],"conflicts":[],"missingFields":[],"reasonSummary":"Synthetic run proof"}
    set result=##class(PI.Policy).Validate(c.id,d,1,9302)
    do ..Assert(result.%Get("error","")="CURRENT_RUN_EVIDENCE_REQUIRED","same-version prior-run evidence rejected")
    set result=##class(PI.Policy).Validate(c.id,d,1,9301)
    do ..Assert(result.decision="LINK_REVIEW","actual evidence from expected run accepted")
    do ##class(PI.Tools).End()
    write "PHASE1_RUN_EVIDENCE_OK",!
}
}
