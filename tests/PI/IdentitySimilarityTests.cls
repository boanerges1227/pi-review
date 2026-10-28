Class PI.IdentitySimilarityTests Extends PI.Tests
{
/// Exercise the real IRIS Embedded Python boundary and preserve deterministic identity decisions.
ClassMethod Run()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.IdentitySimilarity"),"embedded name comparison is installed")
    set result=##class(PI.IdentitySimilarity).CompareNames("  ANNA   SMITH ","anna smith")
    do ..Assert(result.comparable&&(result.score=1),"case and whitespace are explanatory equivalents")
    set result=##class(PI.IdentitySimilarity).CompareNames($char(65313,65326,65326,65313),"anna")
    do ..Assert(result.score=1,"compatibility characters normalize without changing source records")
    set result=##class(PI.IdentitySimilarity).CompareNames("Anna","Ana")
    do ..Assert((result.score>0.85)&&(result.score<0.86),"a spelling difference has a bounded supporting score")
    set result=##class(PI.IdentitySimilarity).CompareNames("   ","Anna")
    do ..Assert('result.comparable&&(result.score=0),"missing names do not produce identity evidence")
    set tooLong=$justify("",501),caught=0
    try { set result=##class(PI.IdentitySimilarity).CompareNames(tooLong,"Anna") } catch ex { set caught=1 }
    do ..Assert(caught,"name comparison rejects oversized input")
    set a=..Input(),b=..Input("EMR","similarity"),b.identifier="SYN-DIFFERENT"
    set result=##class(PI.Rules).Compare(a,b)
    do ..Assert(result.identifierConflict,"perfect names cannot erase identifier conflicts")
    do ..Assert(a.name="Alice Chen","source names remain unchanged")
    set candidates=[(b)],baseline=##class(PI.Rules).Baseline(a,candidates)
    do ..Assert(baseline.decision="CONFLICT_REVIEW","similarity never alters the deterministic baseline")
    do ..Reset()
    set first=##class(PI.Store).Ingest(..Input()),second=##class(PI.Store).Ingest(..Input("EMR","similarity-tool"))
    do ##class(PI.Tools).Begin(second.caseId)
    try {
        set evidence=##class(PI.Tools).Compare("r"_first.recordId)
        do ..Assert(evidence.data.nameSimilarity.score=1,"agent comparison collects real Embedded Python evidence")
        set detail=##class(PI.Store).Detail(second.caseId)
        do ..Assert(detail.comparisons.%Get("r"_first.recordId).nameSimilarity.score=1,"readonly views replay persisted supporting evidence")
        set changed=..Input("HIS","p1",2),changed.name="ALICE CHEN",update=##class(PI.Store).Ingest(changed)
        set stale=##class(PI.Store).Detail(second.caseId)
        do ..Assert(stale.stale&&(stale.comparisons.%Size()=0),"candidate source updates hide obsolete similarity evidence immediately")
        set refreshed=##class(PI.Store).Refresh(second.caseId),fresh=##class(PI.Store).Detail(second.caseId)
        do ..Assert(fresh.comparisons.%Size()=0,"snapshot refresh does not revive old comparison scores")
    } catch ex { do ##class(PI.Tools).End() throw ex }
    do ##class(PI.Tools).End()
    write "IDENTITY_SIMILARITY_TESTS_OK",!
}
}
