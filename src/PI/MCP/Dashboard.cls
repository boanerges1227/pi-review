Class PI.MCP.Dashboard Extends %RegisteredObject
{
/// Return a bounded passive snapshot; never probe tools, resolve secrets, or change business state.
ClassMethod Snapshot(limit As %Integer = 10000) As %DynamicObject
{
    if (limit<1)!(limit>10000) { throw ##class(%Exception.General).%New("INVALID_DASHBOARD_LIMIT") }
    lock +^PIData($namespace,"lock"):2
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set source=..Source(limit),published=..Published(limit),proof=..Evidence(limit),tasks=..Tasks(limit),events=[]
        for i=0:1:source.events.%Size()-1 { do events.%Push(source.events.%Get(i)) }
        for i=0:1:published.events.%Size()-1 { do events.%Push(published.events.%Get(i)) }
        set tools=[]
        for i=1:1:6 {
            set name=$piece("verify_source_record,request_enrichment,get_enrichment,review_case,review_evidence,review_run_trace",",",i),direction=$select(i<=3:"outbound",1:"inbound")
            set group=$select(i<=3:source,1:published),row=group.tools.%Get(name,{"total":0,"ok":0,"failed":0,"durationTotal":0,"durationCount":0})
            set average=""
            if row.durationCount>0 { set average=+$fnumber(row.durationTotal/row.durationCount,"",1) }
            do tools.%Push({"name":(name),"direction":(direction),"total":(row.total),"ok":(row.ok),"failed":(row.failed),"averageMs":(average)})
        }
        set sourceObservation=$select(source.events.%Size()>0:source.events.%Get(0),1:{}),publishedObservation=$select(published.events.%Size()>0:published.events.%Get(0),1:{})
        set servers=[{"id":"source","name":"Synthetic source MCP","role":"Source verification and enrichment","endpoint":"IRIS native MCP :52788","tools":3,"observation":(sourceObservation)}, {"id":"publisher","name":"IRIS review MCP","role":"Readonly case, evidence and run trace","endpoint":"127.0.0.1:52785/mcp","tools":3,"observation":(publishedObservation)}]
        set result={"generatedAtEpoch":(..Now()),"namespace":($namespace),"passive":true,"productionRunning":(##class(Ens.Director).IsProductionRunning()),"servers":(servers),"summary":{"outbound":(source.stats),"published":(published.stats),"verifications":(proof.stats),"enrichment":(tasks.stats)},"tools":(tools),"events":(events),"tasks":(tasks.items),"scan":{"limitPerCollection":(limit),"eventLimitPerDirection":100,"taskLimit":100,"scanned":{"outbound":(source.scanned),"published":(published.scanned),"evidence":(proof.scanned),"tasks":(tasks.scanned)},"truncated":{"outbound":(source.truncated),"published":(published.truncated),"evidence":(proof.truncated),"tasks":(tasks.truncated)}}}
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit result
}

/// Express observation times explicitly in UTC seconds; undated legacy records remain undated.
ClassMethod Now() As %Numeric
{
    set stamp=$ztimestamp
    quit (($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
}

/// Whitelist event fields and known tool names; native tool references can contain credentials.
ClassMethod Event(raw As %DynamicObject, id As %Integer, direction As %String, caseId As %String = "") As %DynamicObject
{
    set name=raw.%Get("tool",""),allowed="verify_source_record,request_enrichment,get_enrichment,review_case,review_evidence,review_run_trace"
    if '$listfind($listfromstring(allowed),name) { set name="other" }
    if direction="inbound" { set caseId=raw.%Get("caseId","") }
    if caseId'?1"c"1.N { set caseId="" }
    set outcome=raw.%Get("outcome","UNKNOWN")
    if '$listfind($listfromstring("OK,FAILED,ALLOWED,DENIED"),outcome) { set outcome="UNKNOWN" }
    set epoch=+raw.%Get("occurredAtEpoch",0),known=(epoch>0),event={"eventId":(id),"direction":(direction),"tool":(name),"outcome":(outcome),"caseId":(caseId),"caseVersion":(+raw.%Get("caseVersion",0)),"runId":(+raw.%Get("runId",0)),"timestampKnown":(known),"occurredAtEpoch":null,"latencyMs":null}
    if known { set event.occurredAtEpoch=epoch }
    if direction="outbound",raw.%IsDefined("elapsedSeconds") { set event.latencyMs=+$fnumber(raw.elapsedSeconds*1000,"",1) }
    if direction="inbound",raw.%IsDefined("durationMs") { set event.latencyMs=+raw.durationMs }
    quit event
}

/// Accumulate tool metrics using the same scanned records as their denominators.
ClassMethod Observe(tools As %DynamicObject, event As %DynamicObject)
{
    set name=event.tool,row=tools.%Get(name,{"total":0,"ok":0,"failed":0,"durationTotal":0,"durationCount":0}),row.total=row.total+1
    if (event.outcome="OK")!(event.outcome="ALLOWED") { set row.ok=row.ok+1 } else { set row.failed=row.failed+1 }
    if event.%GetTypeOf("latencyMs")'="null" { set row.durationTotal=row.durationTotal+event.latencyMs,row.durationCount=row.durationCount+1 }
    do tools.%Set(name,row)
}

/// Aggregate across cases and retain the latest observed completions within the bounded scan.
ClassMethod Source(limit As %Integer) As %DynamicObject
{
    set stats={"total":0,"ok":0,"failed":0,"successRate":null,"averageMs":null,"p95Ms":null},tools={},events=[],scanned=0,truncated=0,caseId="",kept=0,durationTotal=0,durationCount=0
    for {
        set caseId=$order(^PIData($namespace,"mcpTrace",caseId)) quit:caseId=""
        set id=""
        for {
            set id=$order(^PIData($namespace,"mcpTrace",caseId,id)) quit:id=""
            if scanned>=limit { set truncated=1 quit }
            set scanned=scanned+1,event=..Event({}.%FromJSON(^PIData($namespace,"mcpTrace",caseId,id)),+id,"outbound",caseId)
            set stats.total=stats.total+1
            if event.outcome="OK" { set stats.ok=stats.ok+1 } else { set stats.failed=stats.failed+1 }
            if event.%GetTypeOf("latencyMs")'="null" {
                set ms=event.latencyMs,durationTotal=durationTotal+ms,durationCount=durationCount+1,latency(ms)=$get(latency(ms))+1
            }
            do ..Observe(tools,event)
            do ..KeepEvent(.recent,.kept,event)
        }
        quit:truncated
    }
    if stats.total>0 { set stats.successRate=+$fnumber((stats.ok*100)/stats.total,"",1) }
    if durationCount>0 {
        set stats.averageMs=+$fnumber(durationTotal/durationCount,"",1),target=((durationCount*95)+99)\100,cumulative=0,ms=""
        for { set ms=$order(latency(ms)) quit:ms=""  set cumulative=cumulative+latency(ms) if cumulative>=target { set stats.p95Ms=+ms quit } }
    }
    set events=..Ordered(.recent)
    quit {"stats":(stats),"tools":(tools),"events":(events),"scanned":(scanned),"truncated":(truncated)}
}

/// Read only the audit branch, never token digests, actor-token indexes, or grants.
ClassMethod Published(limit As %Integer) As %DynamicObject
{
    set stats={"total":0,"allowed":0,"denied":0,"failed":0},tools={},events=[],id="",scanned=0,truncated=0,kept=0
    for {
        set id=$order(^PIMCPAccess($namespace,"audit",id),-1) quit:id=""
        if scanned>=limit { set truncated=1 quit }
        set scanned=scanned+1,event=..Event({}.%FromJSON(^PIMCPAccess($namespace,"audit",id)),+id,"inbound"),stats.total=stats.total+1
        if event.outcome="ALLOWED" { set stats.allowed=stats.allowed+1 } elseif event.outcome="DENIED" { set stats.denied=stats.denied+1 } else { set stats.failed=stats.failed+1 }
        do ..Observe(tools,event)
        do ..KeepEvent(.recent,.kept,event)
    }
    set events=..Ordered(.recent)
    quit {"stats":(stats),"tools":(tools),"events":(events),"scanned":(scanned),"truncated":(truncated)}
}

/// Use observed completion time for timed events; retain explicit ID fallback only for undated history.
ClassMethod KeepEvent(ByRef rows, ByRef count As %Integer, event As %DynamicObject)
{
    set epoch=$select(event.timestampKnown:+event.occurredAtEpoch,1:0)
    set rows(epoch,event.eventId)=event.%ToJSON(),count=count+1
    if count>100 {
        set firstTime=$order(rows("")),firstId=$order(rows(firstTime,""))
        kill rows(firstTime,firstId)
        set count=100
    }
}

/// Return newest timestamped observations before undated legacy rows, with stable ID tie-breaking.
ClassMethod Ordered(ByRef rows) As %DynamicArray
{
    set result=[],epoch=""
    for {
        set epoch=$order(rows(epoch),-1) quit:epoch=""
        set id=""
        for { set id=$order(rows(epoch,id),-1) quit:id=""  do result.%Push({}.%FromJSON(rows(epoch,id))) }
    }
    quit result
}

/// Count immutable source verification evidence independently of successful network transport.
ClassMethod Evidence(limit As %Integer) As %DynamicObject
{
    set stats={"total":0,"verified":0,"mismatch":0,"unknown":0,"unavailable":0},scanned=0,truncated=0,caseId=""
    for {
        set caseId=$order(^PIData($namespace,"evidence",caseId)) quit:caseId=""
        set version=""
        for {
            set version=$order(^PIData($namespace,"evidence",caseId,version)) quit:version=""
            set id=""
            for {
                set id=$order(^PIData($namespace,"evidence",caseId,version,id)) quit:id=""
                if scanned>=limit { set truncated=1 quit }
                set scanned=scanned+1,e={}.%FromJSON(^PIData($namespace,"evidence",caseId,version,id))
                if e.%Get("tool","")="verify_source_identity" {
                    set data=e.%Get("data",{}),status=$zconvert(data.%Get("status","UNKNOWN"),"L")
                    if '$listfind($listfromstring("verified,mismatch,unknown,unavailable"),status) { set status="unknown" }
                    set stats.total=stats.total+1
                    do stats.%Set(status,stats.%Get(status,0)+1)
                }
            }
            quit:truncated
        }
        quit:truncated
    }
    quit {"stats":(stats),"scanned":(scanned),"truncated":(truncated)}
}

/// Historical READY tasks are not active unless they still match the current waiting case version.
ClassMethod Tasks(limit As %Integer) As %DynamicObject
{
    set stats={"total":0,"active":0,"applied":0,"failed":0,"superseded":0,"legacy":0},items=[],scanned=0,truncated=0,caseId=""
    for {
        set caseId=$order(^PIData($namespace,"enrichment",caseId)) quit:caseId=""
        set c=$select($data(^PIData($namespace,"case",caseId)):{}.%FromJSON($get(^PIData($namespace,"case",caseId))),1:{}),version=""
        for {
            set version=$order(^PIData($namespace,"enrichment",caseId,version),-1) quit:version=""
            if scanned>=limit { set truncated=1 quit }
            set scanned=scanned+1,t={}.%FromJSON(^PIData($namespace,"enrichment",caseId,version))
            if t.%Get("transport","")'="mcp" { set stats.legacy=stats.legacy+1 continue }
            set stats.total=stats.total+1,status=t.%Get("status","UNKNOWN"),active=0
            if '$listfind($listfromstring("REQUESTING,READY,WAITING,FAILED,APPLIED,SUPERSEDED"),status) { set status="UNKNOWN" }
            if (status="READY")!(status="WAITING") {
                set active=(c.%Get("status","")="NEEDS_DATA")&&(c.%Get("version",0)=t.%Get("waitingVersion",-1))&&(c.%Get("enrichmentVersion",0)=t.%Get("waitingVersion",-1))
            }
            if status="REQUESTING" { set active=(c.%Get("version",0)=t.%Get("originVersion",-1))&&'$listfind($listfromstring("APPROVED,REJECTED"),c.%Get("status","")) }
            if active { set stats.active=stats.active+1 }
            if status="APPLIED" { set stats.applied=stats.applied+1 }
            if status="FAILED" { set stats.failed=stats.failed+1 }
            if status="SUPERSEDED" { set stats.superseded=stats.superseded+1 }
            if items.%Size()<100 {
                do items.%Push({"caseId":(caseId),"originVersion":(+t.%Get("originVersion",0)),"waitingVersion":(+t.%Get("waitingVersion",version)),"status":(status),"active":(active),"sourceStatus":($select($listfind($listfromstring("READY,WAITING,FAILED"),t.%Get("sourceStatus","")):t.%Get("sourceStatus"),1:"")),"hasReceipt":(t.%Get("receiptId","")'="")})
            }
        }
        quit:truncated
    }
    quit {"stats":(stats),"items":(items),"scanned":(scanned),"truncated":(truncated)}
}
}
