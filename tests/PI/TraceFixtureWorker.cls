Class PI.TraceFixtureWorker Extends Ens.BusinessOperation
{
Parameter INVOCATION = "InProc";
/// Exercise the actual SDK tool loop and the production trace scope, using only a loopback fixture.
Method OnMessage(request As PI.Trace.RunRequest, Output response As PI.Trace.Ack) As %Status
{
    new %PITraceScope
    set %PITraceScope=##class(PI.Trace.Scope).Start($this,request.RunId,request.CaseId,1,..%SessionId,"synthetic"),ok=0
    try {
        set base=%PITraceScope.Configure("openai","http://127.0.0.1:18891/v1/",request.CaseId)
        set provider=##class(%AI.Provider).Create("openai",{"api_key":"FIXTURE_SECRET_KEY_MARKER","base_url":(base),"http_config":{"request_timeout_secs":5,"connect_timeout_secs":1}})
        set agent=##class(%AI.Agent).%New(provider),agent.Model=request.CaseId,agent.SystemPrompt="FIXTURE_SECRET_PROMPT_CONTENT"
        do agent.UseToolSet("PI.TraceFixtureTools")
        set sc=agent.ToolManager.SetAuditPolicy(##class(PI.ToolAudit).%New())
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set session=agent.CreateSession({"max_iterations":4,"max_tokens":100}),before=session.GetStats()
        do %PITraceScope.Emit({"kind":"sdk.start","spanId":"sdk-1","status":"RUNNING"})
        set reply=agent.Chat(session,"Use both synthetic tools and return a result.")
        do %PITraceScope.Drain()
        do %PITraceScope.SdkEnd(session.GetStats(),1)
        if request.CaseId="fixture-repeat" {
            set previous=session.GetStats(),%PITraceScope.SdkSpan="sdk-2",%PITraceScope.PromptVersion="pi-followup-fixture-v1"
            do %PITraceScope.Emit({"kind":"sdk.start","spanId":"sdk-2","status":"RUNNING"})
            set reply=agent.Chat(session,"Use both synthetic tools again.")
            do %PITraceScope.Drain()
            set current=session.GetStats(),delta={"total_prompt_tokens":(current.%Get("total_prompt_tokens",0)-previous.%Get("total_prompt_tokens",0)),"total_completion_tokens":(current.%Get("total_completion_tokens",0)-previous.%Get("total_completion_tokens",0))}
            do %PITraceScope.SdkEnd(delta,1)
        }
        set ok=1
    } catch ex {
        try { do %PITraceScope.Drain() do %PITraceScope.Emit({"kind":"sdk.end","spanId":"sdk-1","status":"FAILED","errorCode":"SDK_FAILED"}) } catch tracing { set %PITraceScope.Failed=1 }
    }
    do %PITraceScope.Finish(ok)
    set response=##class(PI.Trace.Ack).%New(),response.Accepted=1,response.TraceId=%PITraceScope.TraceId,response.NativeSessionId=..%SessionId
    quit 1
}
}
