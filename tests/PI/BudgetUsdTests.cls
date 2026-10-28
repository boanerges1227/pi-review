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
