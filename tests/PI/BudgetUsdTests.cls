Class PI.BudgetUsdTests Extends PI.Tests
{
/// Preserve legacy purchasing authorization and audit history while converting all monetary ledger values exactly once.
ClassMethod Migration()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIBudget($namespace),^PIBudgetArchive($namespace)
    set ^PIBudget($namespace,"spentCny")=.87778,^PIBudget($namespace,"reservedCny")=0,^PIBudget($namespace,"unknownCny")=0,^PIBudget($namespace,"seq")=4
    for id=1:1:4 {
        set ^PIBudget($namespace,"reservation",id)="CLOSED",^PIBudget($namespace,"reservation",id,"amount")=15
        set ^PIBudget($namespace,"reservation",id,"settledCost")=$piece(".13424,.25258,.21152,.27944",",",id)
    }
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.Budget"),"USD ledger migration is available")
    do ##class(PI.Budget).EnsureUsd()
    set view=##class(PI.Budget).Snapshot()
    do ..Assert(view.currency="USD"&&(view.budgetUsd=3),"currency conversion preserves the original allowance")
    do ..Assert(view.estimatedUsd=.087778&&(view.reservedUsd=0),"historical charges are converted instead of relabeled")
    do ..Assert(^PIBudget($namespace,"reservation",1,"amount")=1.5&&(^PIBudget($namespace,"reservation",1,"settledCost")=.013424),"closed reservation amounts and charges use dollars")
    do ..Assert(^PIBudgetArchive($namespace,"CNY-v1","spentCny")=.87778,"original ledger remains available for audit")
    do ##class(PI.Budget).EnsureUsd()
    do ..Assert(##class(PI.Budget).Snapshot().estimatedUsd=.087778,"repeated initialization never converts history twice")
    set id=##class(PI.Agent).Reserve()
    do ##class(PI.Agent).Settle(id,{"total_prompt_tokens":1000,"total_completion_tokens":1000})
    do ..Assert(^PIBudget($namespace,"spentUsd")=.095778,"new token charges are settled directly in USD")
    do ##class(PI.Agent).Settle(1,{"total_prompt_tokens":1000,"total_completion_tokens":1000})
    do ..Assert(^PIBudget($namespace,"spentUsd")=.095778,"settling a migrated closed reservation is idempotent")
    kill ^PIBudget($namespace),^PIBudgetArchive($namespace)
    set ^PIBudget($namespace,"spentCny")=18,^PIBudget($namespace,"unknownCny")=15
    set ^PIBudget($namespace,"reservation",1)="CLOSED",^PIBudget($namespace,"reservation",1,"amount")=15,^PIBudget($namespace,"reservation",1,"settledCost")=15,^PIBudget($namespace,"reservation",1,"unknownUsage")=1
    set view=##class(PI.Budget).Snapshot()
    do ..Assert(view.estimatedUsd=1.8&&(view.unknownUsageUsd=1.5)&&(view.knownEstimateUsd=.3),"historical unknown usage converts separately from known token costs")
    do ..Assert(^PIBudget($namespace,"reservation",1,"unknownUsage")=1&&(^PIBudget($namespace,"reservation",1,"settledCost")=1.5),"legacy unknown-charge provenance is preserved")
    kill ^PIBudget($namespace)
    write "BUDGET_USD_MIGRATION_OK",!
}

/// Refuse conversion during an old-currency request rather than mixing units or altering an active reservation.
ClassMethod InFlight()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIBudget($namespace),^PIBudgetArchive($namespace)
    set ^PIBudget($namespace,"spentCny")=.5,^PIBudget($namespace,"reservedCny")=15,^PIBudget($namespace,"reservation",1)="OPEN",^PIBudget($namespace,"reservation",1,"amount")=15,denied=0
    try { do ##class(PI.Budget).EnsureUsd() } catch ex { set denied=(ex.Name="BUDGET_MIGRATION_BUSY") }
    do ..Assert(denied,"legacy in-flight charges block migration")
    do ..Assert(^PIBudget($namespace,"spentCny")=.5&&(^PIBudget($namespace,"reservedCny")=15),"blocked migration preserves the original balances")
    do ..Assert('$data(^PIBudget($namespace,"currency"))&&('$data(^PIBudgetArchive($namespace))),"blocked migration leaves no partial new ledger")
    tstart
    set ^PITestUsdOuterTransaction=1,denied=0
    try { do ##class(PI.Budget).EnsureUsd() } catch ex { set denied=(ex.Name="BUDGET_MIGRATION_BUSY") }
    do ..Assert(denied&&($tlevel=1)&&$data(^PITestUsdOuterTransaction),"refused migration does not roll back the caller's transaction")
    trollback
    kill ^PIBudget($namespace)
    write "BUDGET_USD_INFLIGHT_OK",!
}

/// Refuse model investigations beyond the daily allowance and return counts when no model call started.
ClassMethod DailyQuota()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIBudget($namespace)
    set view=##class(PI.Budget).DailySnapshot()
    do ..Assert(view.callsUsed=0&&(view.callLimit=50),"a fresh day starts with the full 50-call allowance")
    set used=0
    for i=1:1:50 { set used=##class(PI.Budget).UseDailyCall() }
    do ..Assert(used=50&&(##class(PI.Budget).DailySnapshot().callsUsed=50),"calls are counted atomically up to the daily limit")
    set denied=0
    try { do ##class(PI.Budget).UseDailyCall() } catch ex { set denied=(ex.Name="DAILY_CALL_LIMIT") }
    do ..Assert(denied,"the fifty-first call on the same day is refused")
    do ##class(PI.Budget).ReleaseDailyCall()
    do ..Assert(##class(PI.Budget).DailySnapshot().callsUsed=49,"a released count returns quota when the model was never called")
    kill ^PIBudget($namespace)
    for i=1:1:49 { do ##class(PI.Budget).UseDailyCall() }
    do ##class(PI.Budget).ReleaseDailyCall()
    do ..Assert(##class(PI.Budget).DailySnapshot().callsUsed=48,"a released count decrements exactly one recorded call")
    kill ^PIBudget($namespace)
    do ##class(PI.Budget).ReleaseDailyCall()
    do ..Assert(##class(PI.Budget).DailySnapshot().callsUsed=0,"releasing an unused allowance cannot drive the count negative")
    kill ^PIBudget($namespace)
    write "BUDGET_DAILY_QUOTA_OK",!
}

/// The stage timeline feeds the workbench progress modal without touching investigation locks.
ClassMethod ProgressTimeline()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIData($namespace,"progress","ctest"),^PIData($namespace,"progressRun","ctest")
    do ##class(PI.Agent).MarkProgress("ctest",7,"quota","reserved")
    set ^PIData($namespace,"progressRun","ctest")=7
    do ##class(PI.Agent).MarkProgress("ctest",7,"model","reasoning")
    set snap=##class(PI.Agent).ProgressSnapshot("ctest")
    do ..Assert(snap.active=1&&(snap.runId=7)&&(snap.events.%Size()=2),"an in-flight run reports its live stage timeline")
    do ..Assert(snap.events.%Get(0).stage="quota"&&(snap.events.%Get(1).stage="model"),"stage events keep chronological order")
    kill ^PIData($namespace,"progressRun","ctest")
    do ##class(PI.Agent).MarkProgress("ctest",7,"complete","LINK_REVIEW")
    set snap=##class(PI.Agent).ProgressSnapshot("ctest")
    do ..Assert(snap.active=0&&(snap.events.%Size()=3),"a finished run stays readable for a late modal but is inactive")
    do ..Assert(snap.dailyCalls.callLimit=50,"the snapshot carries the daily allowance for the modal header")
    set snap=##class(PI.Agent).ProgressSnapshot("cmissing")
    do ..Assert(snap.active=0&&(snap.events.%Size()=0),"an unknown case reports an empty timeline without failing")
    kill ^PIData($namespace,"progress","ctest"),^PIData($namespace,"progressRun","ctest")
    write "AGENT_PROGRESS_OK",!
}

/// Unknown usage remains charged conservatively without increasing the original authorization ceiling.
ClassMethod UnknownUsage()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIBudget($namespace)
    set id=##class(PI.Agent).ReserveAvailable()
    do ##class(PI.Agent).Settle(id,{})
    set view=##class(PI.Budget).Snapshot()
    do ..Assert(view.unknownUsageUsd=1.5&&(view.knownEstimateUsd=0),"unknown allowance is explicitly denominated in dollars")
    set id=##class(PI.Agent).ReserveAvailable()
    do ##class(PI.Agent).Settle(id,{})
    set denied=0
    try { set id=##class(PI.Agent).ReserveAvailable() } catch ex { set denied=(ex.Name="BUDGET_LIMIT") }
    do ..Assert(denied&&(##class(PI.Budget).Snapshot().estimatedUsd=3),"unknown usage cannot expand the three-dollar allowance")
    kill ^PIBudget($namespace)
    write "BUDGET_USD_UNKNOWN_OK",!
}
}
