Class PI.Tests Extends %RegisteredObject
{
/// Separate data partitions alone do not isolate the framework runtime; use distinct physical globals databases as well.
ClassMethod Isolation()
{
    set original=$namespace,$namespace="%SYS"
    set sc=##class(Config.Namespaces).Get("USER",.main)
    set sc=##class(Config.Namespaces).Get("PITEST",.tests)
    set isolated=main("Globals")'=tests("Globals"),$namespace=original
    do ..Assert(isolated,"test globals database must differ from production")
}
/// Clear only synthetic test data in this project's dedicated container without accessing other applications.
ClassMethod Reset()
{
    kill ^PIData($namespace)
}

/// Throw immediately on failure so the command line cannot return an empty success message.
ClassMethod Assert(condition As %Boolean, message As %String)
{
    if 'condition { throw ##class(%Exception.General).%New("ASSERT: "_message) }
    set ^PITestCount=$increment(^PITestCount)
}

/// Create manually defined synthetic incoming records with expected conclusions specified directly by the test.
ClassMethod Input(system As %String = "HIS", patient As %String = "p1", version As %Integer = 1) As %DynamicObject
{
    quit {"sourceSystem":(system),"sourcePatientId":(patient),"sourceVersion":(version),"name":"Alice Chen","birthDate":"1985-05-06","sex":"F","identifier":"SYN-1001","phone":"TEST-PHONE-1","notes":"synthetic"}
}

/// Verify actual persistence, idempotency, conflicting candidate recall, and candidate truncation.
ClassMethod Intake()
{
    do ..Reset()
    set a=..Input(),x=##class(PI.Store).Ingest(a)
    do ..Assert(x.status="ACCEPTED","new patient accepted")
    do ..Assert(x.masterId'="","new patient receives master")
    set y=##class(PI.Store).Ingest(a)
    do ..Assert(y.duplicate=1,"duplicate is idempotent")
    do ..Assert($get(^PIData($namespace,"seq","master"))=1,"no duplicate master")
    set a.name="Other Name",bad=0
    try { set z=##class(PI.Store).Ingest(a) } catch ex { set bad=(ex.Name="VERSION_CONFLICT") }
    do ..Assert(bad,"same version different content rejected")
    set b=..Input("EMR","p2"),b.name="Alicia Chen"
    set z=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(z.caseId)
    do ..Assert(c.candidates.%Size()=1,"same identifier with changed name recalled")
    do ..Assert(c.status="PENDING_AGENT","conflict is investigated")
    set a=..Input("HIS","bad"),a.birthDate="2026-02-30",bad=0
    try { set z=##class(PI.Store).Ingest(a) } catch ex { set bad=(ex.Name="INVALID_BIRTH_DATE") }
    do ..Assert(bad,"invalid calendar date rejected")
    set a=..Input("HIS",""),bad=0
    try { set z=##class(PI.Store).Ingest(a) } catch ex { set bad=(ex.Name="INVALID_SOURCE") }
    do ..Assert(bad,"empty source ID rejected")
    write "INTAKE_TESTS_OK ",^PITestCount,!
}

/// Verify cross-case reads, forged evidence, and hard conflicts cannot bypass constraints.
ClassMethod Policy()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input())
    set b=..Input("EMR","p2"),b.identifier="SYN-9999"
    set x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set e=##class(PI.Tools).Compare("r"_a.recordId),bad=0
    try { set z=##class(PI.Tools).Profile("r99999") } catch ex { set bad=(ex.Name="CANDIDATE_DENIED") }
    do ..Assert(bad,"foreign candidate denied")
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"LINK_REVIEW","candidateId":("r"_a.recordId),"evidenceIds":[(e.evidenceId)],"conflicts":[],"missingFields":[],"reasonSummary":"same name"}
    set v=##class(PI.Policy).Validate(c.id,d)
    do ..Assert(v.decision="CONFLICT_REVIEW","different identifiers block linking")
    set d.decision="SEPARATE_REVIEW",d.evidenceIds=["foreign-evidence"]
    set v=##class(PI.Policy).Validate(c.id,d)
    do ..Assert(v.error="INVALID_EVIDENCE","invented evidence rejected")
    set bad=0
    try { for i=1:1:9 { set e=##class(PI.Tools).Summary() } } catch ex { set bad=(ex.Name="TOOL_LIMIT") }
    do ..Assert(bad,"ninth tool call denied")
    do ##class(PI.Tools).End()
    write "POLICY_TESTS_OK",!
}

/// Review versions, undo, and enrichment must update real storage and prevent duplicate links.
ClassMethod Review()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input())
    set b=..Input("EMR","p2"),b.name="Alicia Chen",x=##class(PI.Store).Ingest(b)
    set c=##class(PI.Store).Case(x.caseId),bad=0
    try { set z=##class(PI.Review).Decide(c.id,0,"LINK","r"_a.recordId,"checked") } catch ex { set bad=(ex.Name="STALE_CASE") }
    do ..Assert(bad,"stale approval rejected")
    set result=##class(PI.Review).Decide(c.id,c.version,"LINK","r"_a.recordId,"evidence checked")
    set record=##class(PI.Store).Record(x.recordId)
    do ..Assert(record.masterId=a.masterId,"approved link changes mapping")
    set bad=0
    try { set z=##class(PI.Review).Decide(c.id,c.version,"LINK","r"_a.recordId,"repeat") } catch ex { set bad=(ex.Name="STALE_CASE") }
    do ..Assert(bad,"duplicate approval cannot change mapping")
    set z=##class(PI.Review).Undo(c.id,result.version,"undo mistaken review"),record=##class(PI.Store).Record(x.recordId)
    do ..Assert(record.masterId="","undo restores old mapping")
    set c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Route).Apply(c.id,{"decision":"NEEDS_DATA","missingFields":["birthDate"],"reasonSummary":"missing"})
    set b.sourceVersion=2,b.birthDate="1985-05-06",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ..Assert(c.rounds=1,"enrichment resumes same case")
    do ..Assert(c.status="PENDING_AGENT","enriched case ready for fresh agent")
    do ##class(PI.Route).Apply(c.id,{"decision":"NEEDS_DATA","missingFields":["phone"],"reasonSummary":"missing"})
    set b.sourceVersion=3,x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ..Assert(c.rounds=2,"second enrichment counted")
    do ..Assert(c.status="CONFLICT_REVIEW","enrichment stops at two rounds")
    write "REVIEW_TESTS_OK",!
}

/// Keep original investigation evidence visible after routing; rebuild a consistent snapshot after source changes.
ClassMethod EvidenceLifecycle()
{
    do ..Reset()
    set base=..Input(),a=##class(PI.Store).Ingest(base)
    set b=..Input("EMR","p2"),b.name="Alicia Chen",x=##class(PI.Store).Ingest(b)
    set c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set evidence=##class(PI.Tools).Compare("r"_a.recordId)
    do ##class(PI.Tools).End()
    do ##class(PI.Route).Apply(c.id,{"decision":"LINK_REVIEW","caseVersion":(c.version),"evidenceIds":[(evidence.evidenceId)]})
    set detail=##class(PI.Store).Detail(c.id)
    do ..Assert(detail.evidence.%Size()=1,"routed case retains investigation evidence")
    set base.sourceVersion=2,base.phone="TEST-PHONE-NEW",z=##class(PI.Store).Ingest(base)
    set changed=##class(PI.Store).Case(c.id)
    do ..Assert(changed.stale=1,"candidate update invalidates review snapshot")
    set fresh=##class(PI.Store).Refresh(c.id)
    do ..Assert(fresh.stale=0,"explicit refresh rebuilds candidate snapshots")
    do ..Assert(fresh.candidates.%Get(0).sourceVersion=2,"fresh candidate includes latest source version")
    set baseline=##class(PI.Rules).Baseline(fresh.incoming,fresh.candidates)
    do ..Assert(baseline.decision="CONFLICT_REVIEW","rule baseline cannot explain corrected spelling from history")
    write "EVIDENCE_LIFECYCLE_TESTS_OK",!
}

/// Reserve budget before concurrent investigations; settle and release the remainder only when full-session usage is verifiable.
ClassMethod Budget()
{
    kill ^PIBudget($namespace)
    set a=##class(PI.Agent).Reserve(),b=##class(PI.Agent).Reserve(),bad=0
    try { set z=##class(PI.Agent).Reserve() } catch ex { set bad=(ex.Name="BUDGET_LIMIT") }
    do ..Assert(bad,"third concurrent run cannot exceed budget")
    do ##class(PI.Agent).Settle(a,{"total_prompt_tokens":1000,"total_completion_tokens":1000})
    do ..Assert(^PIBudget($namespace,"reservedUsd")=1.5,"one dollar reservation remains")
    do ..Assert(^PIBudget($namespace,"spentUsd")=0.008,"full-price conservative dollar usage counted")
    do ##class(PI.Agent).Settle(a,{"total_prompt_tokens":1000,"total_completion_tokens":1000})
    do ..Assert(^PIBudget($namespace,"reservedUsd")=1.5,"settlement is idempotent")
    kill ^PIBudget($namespace)
    write "BUDGET_TESTS_OK",!
}

/// Summary evidence cannot replace field comparison for the specified candidate; missing identity fields must prevent link recommendations.
ClassMethod EvidenceQuality()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),b=..Input("EMR","p2"),x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set e=##class(PI.Tools).Summary()
    set d={"caseId":(c.id),"caseVersion":(c.version),"decision":"LINK_REVIEW","candidateId":("r"_a.recordId),"evidenceIds":[(e.evidenceId)],"conflicts":[],"missingFields":[],"reasonSummary":"same fields"}
    set result=##class(PI.Policy).Validate(c.id,d)
    do ..Assert(result.decision="CONFLICT_REVIEW","summary alone cannot justify association")
    set e=##class(PI.Tools).Compare("r"_a.recordId),d.evidenceIds=[(e.evidenceId)],result=##class(PI.Policy).Validate(c.id,d)
    do ..Assert(result.decision="LINK_REVIEW","matching candidate comparison supports review")
    do ##class(PI.Tools).End()
    set b.sourcePatientId="missing-birth",b.birthDate="",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    do ##class(PI.Tools).Begin(c.id)
    set e=##class(PI.Tools).Compare("r"_a.recordId),d.caseId=c.id,d.caseVersion=c.version,d.evidenceIds=[(e.evidenceId)]
    set result=##class(PI.Policy).Validate(c.id,d)
    do ..Assert(result.decision="CONFLICT_REVIEW","missing birth cannot bypass enrichment")
    do ##class(PI.Tools).End()
    write "EVIDENCE_QUALITY_TESTS_OK",!
}

/// Choosing separation for linked records must create an independent mapping; closed cases cannot start another investigation.
ClassMethod ReviewRegressions()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),b=..Input("EMR","p2"),x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set done=##class(PI.Review).Decide(c.id,c.version,"LINK","r"_a.recordId,"confirmed synthetic evidence")
    set bad=0
    try { do ##class(PI.Tools).Begin(c.id) } catch ex { set bad=(ex.Name="CASE_CLOSED") }
    do ..Assert(bad,"closed review cannot start a new investigation")
    set after=##class(PI.Store).Case(c.id)
    do ..Assert((after.status="APPROVED")&&(after.version=done.version),"investigation startup cannot reopen approval")
    write "REVIEW_REGRESSIONS_OK",!
}

/// When a new source version is confirmed as separate, stop reusing its previously shared master index.
ClassMethod Separation()
{
    do ..Reset()
    set a=##class(PI.Store).Ingest(..Input()),b=..Input("EMR","p2"),x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set done=##class(PI.Review).Decide(c.id,c.version,"LINK","r"_a.recordId,"confirmed synthetic evidence")
    set b.sourceVersion=2,b.identifier="SYN-OTHER",x=##class(PI.Store).Ingest(b),c=##class(PI.Store).Case(x.caseId)
    set done=##class(PI.Review).Decide(c.id,c.version,"SEPARATE","","different identity confirmed")
    set record=##class(PI.Store).Record(x.recordId)
    do ..Assert(record.masterId'=a.masterId,"keep separate removes shared mapping")
    do ..Assert(record.masterId'="","separate record has independent master")
    write "SEPARATION_TESTS_OK",!
}

/// Verify candidate limits, investigation timeouts, and enrichment timeouts exit explicitly instead of silently continuing.
ClassMethod LimitsAndRecovery()
{
    do ..Reset()
    for i=1:1:11 {
        set r=..Input("HIS","limit-"_i),r.identifier="SYN-LIMIT-"_i,x=##class(PI.Store).Ingest(r)
    }
    set r=..Input("EMR","overflow"),r.identifier="SYN-LIMIT-X",x=##class(PI.Store).Ingest(r),c=##class(PI.Store).Case(x.caseId)
    do ..Assert(c.candidates.%Size()=10,"candidate count is bounded")
    do ..Assert(c.truncated=1,"candidate overflow is explicit")
    do ..Assert(c.status="CONFLICT_REVIEW","overflow goes to human conflict queue")
    do ##class(PI.Tools).Begin(c.id)
    set ^PIData($namespace,"context",$job,"start")=$zh-121,bad=0
    try { set e=##class(PI.Tools).Summary() } catch ex { set bad=(ex.Name="AGENT_TIMEOUT") }
    do ..Assert(bad,"tool deadline rejects further investigation")
    do ##class(PI.Tools).End()
    do ##class(PI.Route).Apply(c.id,{"decision":"NEEDS_DATA","missingFields":["identifier"],"reasonSummary":"synthetic timeout fixture"})
    set c=##class(PI.Store).Case(c.id),c.requestedAt="0,0",^PIData($namespace,"case",c.id)=c.%ToJSON()
    do ##class(PI.Route).Expire()
    set c=##class(PI.Store).Case(c.id)
    do ..Assert(c.status="CONFLICT_REVIEW","expired enrichment exits to human")
    do ..Assert(c.result.error="ENRICHMENT_TIMEOUT","timeout has an explicit reason")
    write "LIMITS_AND_RECOVERY_OK",!
}
}
