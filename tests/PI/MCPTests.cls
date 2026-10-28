Class PI.MCPTests Extends %RegisteredObject
{
/// Exercise actual native remote tools and prove mandatory source evidence cannot be invented.
ClassMethod SourceEvidence()
{
    do ##class(PI.Tests).Reset()
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.Tools||VerifySource"),"MCP wrapper must be implemented")
    set a=##class(PI.Tests).Input("HIS","MCP-HIS-A"),a.identifier="SYN-MCP-1001",a.name="MCP Avery Chen",a.birthDate="1988-03-17",base=##class(PI.Store).Ingest(a)
    set b=##class(PI.Tests).Input("EMR","MCP-EMR-A"),b.identifier="SYN-MCP-1001",b.name="MCP Avery Chen",b.birthDate="1988-03-17",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set ^PIData($namespace,"context",$job,"runId")=77
    set comp=##class(PI.Tools).Compare("r"_base.recordId)
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"LINK_REVIEW","candidateId":("r"_base.recordId),"evidenceIds":[(comp.evidenceId)],"conflicts":[],"missingFields":[],"reasonSummary":"source proof required"}
    set result=##class(PI.Policy).Validate(c.id,d,0,77,1)
    do ##class(PI.Tests).Assert(result.%Get("error","")="SOURCE_VERIFICATION_REQUIRED","missing remote proof blocks a link")
    set incoming=##class(PI.Tools).VerifySource(c.incoming.id)
    do ##class(PI.Tests).Assert(incoming.data.status="VERIFIED","incoming verified over real MCP")
    do d.evidenceIds.%Push(incoming.evidenceId)
    set result=##class(PI.Policy).Validate(c.id,d,0,77,1)
    do ##class(PI.Tests).Assert(result.%Get("error","")="CANDIDATE_SOURCE_REQUIRED","candidate source also required")
    set candidate=##class(PI.Tools).VerifySource("r"_base.recordId)
    do d.evidenceIds.%Push(candidate.evidenceId)
    set result=##class(PI.Policy).Validate(c.id,d,0,77,1)
    do ##class(PI.Tests).Assert(result.decision="LINK_REVIEW","actual scoped current-run source evidence permits recommendation")
    set bad=0
    try { set denied=##class(PI.Tools).VerifySource("r999999") } catch ex { set bad=(ex.Name="CANDIDATE_DENIED") }
    do ##class(PI.Tests).Assert(bad,"foreign record verification denied before network")
    set c.incoming.name="Forged Name",^PIData($namespace,"case",c.id)=c.%ToJSON(),mismatch=##class(PI.Tools).VerifySource(c.incoming.id)
    do ##class(PI.Tests).Assert(mismatch.data.status="MISMATCH","same version changed fields are not verified")
    do ##class(PI.Tools).End()
}

/// Fetch a real durable enrichment task and protect completed human decisions from late responses.
ClassMethod Enrichment()
{
    do ##class(PI.Tests).Reset()
    set a=##class(PI.Tests).Input("HIS","MCP-HIS-A"),a.identifier="SYN-MCP-1001",a.name="MCP Avery Chen",a.birthDate="1988-03-17",base=##class(PI.Store).Ingest(a)
    set b=##class(PI.Tests).Input("CHECKUP","MCP-CHECKUP-A"),b.identifier="",b.name="MCP Avery Chen",b.birthDate="1988-03-17",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set waiting=##class(PI.Route).Apply(c.id,{"decision":"NEEDS_DATA","caseVersion":(c.version),"missingFields":["identifier"]})
    do ##class(PI.Tests).Assert(waiting.version=c.version+1,"waiting version advances after request")
    set detail=##class(PI.Store).Detail(c.id)
    do ##class(PI.Tests).Assert(detail.enrichment.transport="mcp","enrichment is sent through actual MCP")
    set result=##class(PI.MCP.Enrichment).Fetch(c.id,waiting.version),updated=##class(PI.Store).Case(c.id)
    do ##class(PI.Tests).Assert((result.caseId=c.id)&&(updated.incoming.sourceVersion=2),"MCP update reenters same case with higher source version")
    do ##class(PI.Tests).Assert(updated.incoming.identifier="SYN-MCP-1001","source update supplies actual requested value")
    do ##class(PI.Tests).Assert(updated.rounds=1,"one completed enrichment round")
    set bad=0
    try { set again=##class(PI.MCP.Enrichment).Fetch(c.id,waiting.version) } catch ex { set bad=(ex.Name="STALE_CASE") }
    do ##class(PI.Tests).Assert(bad,"duplicate stale fetch cannot rewrite updated case")
    set waiting=##class(PI.Route).Apply(c.id,{"decision":"NEEDS_DATA","caseVersion":(updated.version),"missingFields":["phone"]})
    set approved=##class(PI.Review).Decide(c.id,waiting.version,"LINK","r"_base.recordId,"synthetic checked"),bad=0
    try { set result=##class(PI.MCP.Enrichment).ApplyUpdate(c.id,waiting.version,{}, {}) } catch ex { set bad=(ex.Name="STALE_CASE")!(ex.Name="CASE_CLOSED") }
    do ##class(PI.Tests).Assert(bad,"late callback cannot overwrite human approval")
}
/// Check actor scoping and stale-version rejection independently of the native network bridge.
ClassMethod Publishing()
{
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.MCP.Access||Check"),"readonly MCP authorization must be implemented")
    set c=##class(PI.Store).Case("c1"),hash=##class(PI.MCP.Access).Hash("synthetic-test-token")
    set ^PIMCPAccess($namespace,"token",hash)="test-reader",^PIMCPAccess($namespace,"grant","test-reader",c.id)=1
    do ##class(PI.MCP.Access).Authenticate("synthetic-test-token")
    set data=##class(PI.MCP.ReadTools).ReviewCase(c.id,c.version)
    do ##class(PI.Tests).Assert(data.id=c.id,"authorized reader sees granted case")
    set bad=0
    try { set data=##class(PI.MCP.ReadTools).ReviewCase(c.id,c.version-1) } catch ex { set bad=1 }
    do ##class(PI.Tests).Assert(bad,"readonly tool rejects stale version")
    set bad=0
    try { set data=##class(PI.MCP.ReadTools).ReviewCase("c99999",1) } catch ex { set bad=1 }
    do ##class(PI.Tests).Assert(bad,"readonly tool rejects ungranted case")
    set bad=0
    try { do ##class(PI.MCP.Access).Authenticate("invalid-token") } catch ex { set bad=1 }
    do ##class(PI.Tests).Assert(bad&&($get(^||PIMCP("actor"))=""),"failed authentication clears previous actor context")
    kill ^PIMCPAccess($namespace,"token",hash),^PIMCPAccess($namespace,"grant","test-reader")
}
/// A stopped source must produce unavailable evidence and manual routing, never a fulfilled task.
ClassMethod Offline()
{
    set b=##class(PI.Tests).Input("EMR","MCP-EMR-A"),b.identifier="SYN-MCP-1001",b.name="MCP Avery Chen",b.birthDate="1988-03-17",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set e=##class(PI.Tools).VerifySource(c.incoming.id)
    do ##class(PI.Tests).Assert(e.data.status="UNAVAILABLE","offline source cannot fabricate verified evidence")
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"NEEDS_DATA","evidenceIds":[(e.evidenceId)],"conflicts":[],"missingFields":["phone"],"reasonSummary":"offline"}
    set checked=##class(PI.Policy).Validate(c.id,d,0,0,1)
    do ##class(PI.Tests).Assert(checked.error="SOURCE_VERIFICATION_REQUIRED","offline evidence fails mandatory source validation")
    do ##class(PI.Tools).End()
    set routed=##class(PI.Route).Apply(c.id,d)
    do ##class(PI.Tests).Assert((routed.status="CONFLICT_REVIEW")&&(routed.result.error="SOURCE_MCP_UNAVAILABLE"),"failed source request exits to manual review")
    write "MCP_OFFLINE_OK ",^PITestCount,!
}
/// Start a read while a source transaction owns the business lock, then advance its version before release.
ClassMethod ReadRace()
{
    set c=##class(PI.Store).Case("c1"),hash=##class(PI.MCP.Access).Hash("synthetic-race-token")
    set ^PIMCPAccess($namespace,"token",hash)="race-reader",^PIMCPAccess($namespace,"grant","race-reader",c.id)=1
    for tool="review_evidence","review_run_trace" {
        kill ^PITestRace($namespace)
        lock +^PIData($namespace,"lock"):3
        if '$test { throw ##class(%Exception.General).%New("TEST_BUSY") }
        job ..ReadWorker(c.id,c.version,tool)
        set pid=$zchild,start=$zh
        for { quit:$get(^PITestRace($namespace,"started"))  quit:($zh-start)>3  hang 0.01 }
        hang 0.2
        set c.version=c.version+1,^PIData($namespace,"case",c.id)=c.%ToJSON()
        lock -^PIData($namespace,"lock")
        set start=$zh
        for { quit:$data(^PITestRace($namespace,"result"))  quit:($zh-start)>5  hang 0.01 }
        if '$data(^PITestRace($namespace,"result")) { do $system.Process.Terminate(pid) }
        do ##class(PI.Tests).Assert($get(^PITestRace($namespace,"result"))="STALE_CASE","read cannot accept an old version while a concurrent update owns the lock")
    }
    kill ^PIMCPAccess($namespace,"token",hash),^PIMCPAccess($namespace,"grant","race-reader"),^PITestRace($namespace)
    write "MCP_READ_RACE_OK",!
}

/// Authenticate in the actual worker process; no test-only hook is added to production methods.
ClassMethod ReadWorker(caseId As %String, version As %Integer, tool As %String)
{
    do ##class(PI.MCP.Access).Authenticate("synthetic-race-token")
    set ^PITestRace($namespace,"started")=1
    try {
        if tool="review_evidence" { set result=##class(PI.MCP.ReadTools).ReviewEvidence(caseId,version) } else { set result=##class(PI.MCP.ReadTools).ReviewRunTrace(caseId,version) }
        set ^PITestRace($namespace,"result")="READ_OK"
    } catch ex { set ^PITestRace($namespace,"result")=ex.Name }
}

/// Prepare a real outbound request while the test runner holds the independent source database lock.
ClassMethod PrepareRouteRace(action As %String)
{
    do ##class(PI.Tests).Reset()
    kill ^PITestRouteRace($namespace)
    set a=##class(PI.Tests).Input("HIS","MCP-HIS-A"),a.identifier="SYN-MCP-1001",a.name="MCP Avery Chen",a.birthDate="1988-03-17",base=##class(PI.Store).Ingest(a)
    set b=##class(PI.Tests).Input("EMR","MCP-EMR-A"),b.identifier="SYN-MCP-1001",b.name="MCP Avery Chen",b.birthDate="1988-03-17",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    job ..RouteWorker(c.id,c.version)
    set ^PITestRouteRace($namespace,"pid")=$zchild,start=$zh
    for { quit:$data(^PIData($namespace,"enrichment",c.id,c.version+1))  quit:($zh-start)>5  hang 0.01 }
    do ##class(PI.Tests).Assert($data(^PIData($namespace,"enrichment",c.id,c.version+1)),"request persisted before concurrent change")
    if action="approve" { set result=##class(PI.Review).Decide(c.id,c.version,"LINK","r"_base.recordId,"synthetic racing approval") } else {
        set b.sourceVersion=2,result=##class(PI.Store).Ingest(b)
    }
    set ^PITestRouteRace($namespace,"expected")=$select(action="approve":"APPROVED",1:"PENDING_AGENT")
    write "MCP_ROUTE_RACE_PREPARED",!
}

/// Exercise the real MCP path; the source database gate delays the network response deterministically.
ClassMethod RouteWorker(caseId As %String, version As %Integer)
{
    try { set result=##class(PI.Route).Apply(caseId,{"decision":"NEEDS_DATA","caseVersion":(version),"missingFields":["phone"]}) set outcome="UNEXPECTED_SUCCESS" } catch ex { set outcome=ex.Name }
    set ^PITestRouteRace($namespace,"result")=outcome
}

/// Require a terminal superseded state and actual source receipt without changing the winning case state.
ClassMethod CheckRouteRace()
{
    set start=$zh
    for { quit:$data(^PITestRouteRace($namespace,"result"))  quit:($zh-start)>15  hang 0.01 }
    if '$data(^PITestRouteRace($namespace,"result")) { do $system.Process.Terminate(^PITestRouteRace($namespace,"pid")) }
    set c=##class(PI.Store).Case("c1"),task={}.%FromJSON(^PIData($namespace,"enrichment","c1",2))
    do ##class(PI.Tests).Assert(c.status=^PITestRouteRace($namespace,"expected"),"concurrent human or source change must win")
    do ##class(PI.Tests).Assert(task.status="SUPERSEDED","late response finalizes request instead of leaving REQUESTING")
    do ##class(PI.Tests).Assert(task.%Get("receiptId","")'="","superseded remote request retains actual receipt")
    write "MCP_ROUTE_RACE_OK",!
}
}
