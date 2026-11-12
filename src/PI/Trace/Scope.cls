Class PI.Trace.Scope Extends %RegisteredObject
{
Property Host As Ens.BusinessOperation;
Property TraceId As %String;
Property RunId As %Integer;
Property CaseId As %String;
Property CaseVersion As %Integer;
Property NativeSessionId As %String;
Property NativeParentMessageId As %String;
Property SdkInvocationId As %String;
Property Coverage As %String [ InitialExpression = "pending" ];
Property RelayHandle As %String;
Property Sequence As %Integer [ InitialExpression = 0 ];
Property Provider As %String;
Property Model As %String;
Property PromptVersion As %String [ InitialExpression = "pi-agent-v1" ];
Property SdkSpan As %String [ InitialExpression = "sdk-1" ];
Property SdkSessionId As %String;
Property Mode As %String [ InitialExpression = "live" ];
Property Rates As %DynamicObject;
Property ApplicationAttempt As %Integer [ InitialExpression = 1 ];
Property ToolEvents As %DynamicArray;
Property ToolSequence As %Integer [ InitialExpression = 0 ];
Property FinalAccepted As %Boolean [ InitialExpression = 0 ];
Property LastHttpSpan As %String;
Property Fallback As %String [ InitialExpression = "none" ];
Property ResponseCount As %Integer [ InitialExpression = 0 ];
Property KnownUsageCount As %Integer [ InitialExpression = 0 ];
Property Failed As %Boolean [ InitialExpression = 0 ];

/// Bind one scope to the real AgentReview worker and its existing native Production session.
ClassMethod Start(host As Ens.BusinessOperation, runId As %Integer, caseId As %String, version As %Integer, nativeSession As %String, mode As %String = "live") As PI.Trace.Scope
{
    set scope=..%New(),scope.Host=host,scope.TraceId=$system.Util.CreateGUID(),scope.RunId=runId,scope.CaseId=caseId,scope.CaseVersion=version,scope.NativeSessionId=nativeSession,scope.Mode=mode
    set scope.SdkInvocationId="execution:"_scope.TraceId
    if $isobject(host.%RequestHeader) { set scope.NativeParentMessageId=host.%RequestHeader.%Id() }
    do scope.Emit({"kind":"run.start","spanId":"run","status":"RUNNING"})
    quit scope
}

/// Observe actual HTTP attempts for supported SDK providers and preserve Google SDK behavior explicitly.
Method Configure(adapter As %String, base As %String, model As %String) As %String
{
    set ..Model=model,..Provider=adapter
    if (adapter="gemini")!(adapter="google") { set ..Coverage="sdk-invocation-only" quit base }
    if '$listfind($listfromstring("openai,anthropic,nim"),adapter) { throw ##class(%Exception.General).%New("TRACE_FAILED") }
    if adapter="anthropic",$extract(base,$length(base)-2,*)'="/v1",$extract(base,$length(base)-3,*)'="/v1/" { set base=$zstrip(base,">","/")_"/v1/" }
    set ..Coverage="http-attempts"
    try {
        set ..RelayHandle=##class(PI.Trace.RelayBridge).Start(##class(PI.InstallPaths).Root(),base)
        return ##class(PI.Trace.RelayBridge).URL(..RelayHandle)
    } catch ex { set ..Failed=1 throw ##class(%Exception.General).%New("TRACE_FAILED") }
}

/// Map only a fixed allowlist from sanitized observer metadata into the native schema.
Method Emit(metadata As %DynamicObject)
{
    try {
        set event=##class(PI.Trace.Event).%New(),event.TraceId=..TraceId,event.RunId=..RunId,event.CaseId=..CaseId,event.CaseVersion=..CaseVersion,event.NativeSessionId=..NativeSessionId,event.NativeParentMessageId=..NativeParentMessageId,event.SdkInvocationId=..SdkInvocationId,event.PromptVersion=..PromptVersion,event.Provider=..Provider,event.TraceMode=..Mode,event.SdkSessionId=..SdkSessionId,event.CostBasis="unknown",event.Coverage=..Coverage,event.Sequence=..Sequence+1,..Sequence=event.Sequence,event.Model=..Model,event.ParentSpanId="run",event.CostKnown=0,event.Fallback=..Fallback,event.Status="UNKNOWN",event.RetryKind="none"
        set mapping="kind:Kind,spanId:SpanId,startedAt:StartedAt,endedAt:EndedAt,status:Status,errorCode:ErrorCode,retryOf:RetryOf,retryKind:RetryKind,toolName:ToolName"
        for i=1:1:$length(mapping,",") { set pair=$piece(mapping,",",i),key=$piece(pair,":",1) if metadata.%GetTypeOf(key)="string" { set $property(event,$piece(pair,":",2))=metadata.%Get(key) } }
        set mapping="durationMs:DurationMs,httpStatus:HttpStatus,inputTokens:InputTokens,outputTokens:OutputTokens,toolCallCount:ToolCallCount"
        for i=1:1:$length(mapping,",") { set pair=$piece(mapping,",",i),key=$piece(pair,":",1) if metadata.%GetTypeOf(key)="number" { set $property(event,$piece(pair,":",2))=metadata.%Get(key) } }
        if metadata.%IsDefined("usageKnown") { if (metadata.%GetTypeOf("usageKnown")="boolean")!(metadata.%GetTypeOf("usageKnown")="number") { set event.UsageKnown=(metadata.%Get("usageKnown",0)=1) } }
        if $extract(event.Kind,1,5)="model" { set event.ParentSpanId=..SdkSpan,event.AttemptSequence=+$piece(event.SpanId,"-",2) }
        if event.Kind="model.request",..ApplicationAttempt>1,event.RetryKind="none" { set event.RetryKind="application-json-repair",event.RetryOf="sdk-1" }
        if event.UsageKnown,$isobject(..Rates) { set event.EstimatedCostUsd=((event.InputTokens*..Rates.input)+(event.OutputTokens*..Rates.output))/1000000,event.CostKnown=1,event.CostBasis="configured-planning-rate" }
        if event.Status="OK" { set event.Status="SUCCEEDED" }
        if (event.Kind="model.request")&&(event.Status="UNKNOWN") { set event.Status="RUNNING" }
        if $extract(event.Kind,1,4)="tool" { set event.ParentSpanId=metadata.%Get("parentSpanId",$select(..LastHttpSpan'="":..LastHttpSpan,1:"run")) }
        if event.Kind="model.response" { set ..LastHttpSpan=event.SpanId,..ResponseCount=..ResponseCount+1 if event.UsageKnown { set ..KnownUsageCount=..KnownUsageCount+1 } }
        if event.StartedAt="" { set event.StartedAt=..UTC() }
        if event.SpanId="run" { set event.ParentSpanId="" }
        do event.Validate()
        set target=$select($extract(event.Kind,1,5)="model":"ModelTrace",$extract(event.Kind,1,4)="tool":"ToolTrace",1:"RunTrace")
        set sc=..Host.SendRequestSync(target,event,.ack,10,"AI sanitized metadata")
        if $system.Status.IsError(sc)!('$isobject(ack)) { throw ##class(%Exception.General).%New("TRACE_FAILED") }
        if 'ack.Accepted { throw ##class(%Exception.General).%New("TRACE_FAILED") }
    } catch ex { set ..Failed=1 throw ##class(%Exception.General).%New("TRACE_FAILED") }
}

/// Build a UTC payload timestamp independently of the later native header emission time.
ClassMethod UTC(stamp As %String = "") As %String
{
    if stamp="" { set stamp=$ztimestamp }
    quit $translate($zdatetime(stamp,3,1,6)," ","T")_"Z"
}

/// Buffer sanitized callback metadata in ObjectScript RAM; Rust callback reentry into Embedded Python is unsafe.
Method Tool(name As %String, duration As %Integer, succeeded As %Boolean, denied As %Boolean = 0)
{
    set end=$ztimestamp,start=end
    if 'denied {
        set seconds=$piece(end,",",2)-(duration/1000),days=+$piece(end,",",1)
        if seconds<0 { set days=days-1,seconds=seconds+86400 }
        set start=days_","_seconds
    }
    if '$listfind($listfromstring("get_case_summary,get_candidate_profile,get_source_history,compare_identity_fields,get_source_policy,search_governance_rules,verify_source_identity"),name) { set name="unregistered" }
    if '$isobject(..ToolEvents) { set ..ToolEvents=[] }
    if ..ToolEvents.%Size()>=64 { set ..Failed=1 throw ##class(%Exception.General).%New("TRACE_FAILED") }
    set ..ToolSequence=..ToolSequence+1,n=..ToolSequence
    do ..ToolEvents.%Push({"kind":($select(denied:"tool.denial",1:"tool.execution")),"spanId":("tool-"_n),"toolName":(name),"startedAt":(..UTC(start)),"endedAt":(..UTC(end)),"durationMs":(duration),"status":($select(denied:"DENIED",succeeded:"SUCCEEDED",1:"FAILED")),"errorCode":($select(denied:"TOOL_DENIED",succeeded:"",1:"TOOL_FAILED"))})
}

/// Merge actual HTTP and tool timestamps after the SDK returns; native headers record their later emission time.
Method Drain()
{
    try {
        set events=[]
        if ..RelayHandle'="" { set events=[].%FromJSON(##class(PI.Trace.RelayBridge).Drain(..RelayHandle)) }
        if $isobject(..ToolEvents) {
            // SDK callbacks execute the response's tool list in order; bind hierarchy before timestamp ordering.
            set toolIndex=0
            for i=0:1:events.%Size()-1 {
                set observed=events.%Get(i)
                if observed.%Get("kind","")="model.response" {
                    set count=+observed.%Get("toolCallCount",0)
                    for j=1:1:count {
                        quit:toolIndex'<..ToolEvents.%Size()
                        set toolEvent=..ToolEvents.%Get(toolIndex),toolIndex=toolIndex+1
                        do toolEvent.%Set("parentSpanId",observed.%Get("spanId","run"))
                    }
                }
            }
            for i=0:1:..ToolEvents.%Size()-1 { do events.%Push(..ToolEvents.%Get(i)) }
            set ..ToolEvents=[]
        }
        for i=0:1:events.%Size()-1 { set metadata=events.%Get(i),ordered(metadata.%Get("startedAt",""),i)=metadata }
        set stamp=""
        for { set stamp=$order(ordered(stamp)) quit:stamp=""  set n="" for { set n=$order(ordered(stamp,n)) quit:n=""  do ..Emit(ordered(stamp,n)) } }
    } catch ex { set ..Failed=1 throw ##class(%Exception.General).%New("TRACE_FAILED") }
}

/// Mark completion and always stop the RAM-only relay, even if persistence or the SDK failed.
Method Finish(succeeded As %Boolean)
{
    try { do ..Drain() } catch ex { set ..Failed=1 }
    if ..RelayHandle'="" { try { do ##class(PI.Trace.RelayBridge).Stop(..RelayHandle) } catch ex { set ..Failed=1 } set ..RelayHandle="" }
    try {
        do ..Emit({"kind":"run.end","spanId":"run","status":($select(succeeded&&('..Failed):"SUCCEEDED",1:"FAILED")),"errorCode":($select(..Failed:"TRACE_FAILED",succeeded:"",1:"RUN_FAILED"))})
        set ..FinalAccepted=('..Failed)
    } catch ex { set ..Failed=1 }
}

/// Record aggregate SDK statistics without interpreting missing provider usage as zero-cost evidence.
Method SdkEnd(stats As %DynamicObject, succeeded As %Boolean)
{
    set known=0,input=stats.%Get("total_prompt_tokens",0),output=stats.%Get("total_completion_tokens",0)
    if (..Coverage="http-attempts")&&(..ResponseCount>0)&&(..ResponseCount=..KnownUsageCount) { set known=1 }
    if (..Coverage="sdk-invocation-only")&&((input+output)>0) { set known=1 }
    set metadata={"kind":"sdk.end","spanId":(..SdkSpan),"status":($select(succeeded:"SUCCEEDED",1:"FAILED")),"errorCode":($select(succeeded:"",1:"SDK_FAILED")),"usageKnown":(known)}
    if known { set metadata.inputTokens=input,metadata.outputTokens=output }
    do ..Emit(metadata)
}
}
