Class PI.Budget Extends %RegisteredObject
{
Parameter LIMITUSD = 3;
/// Maximum number of AI model investigations allowed per calendar day (server local date).
Parameter DAILYCALLLIMIT = 50;

/// Count one AI model call against today's allowance; refuse when the daily limit is already reached.
ClassMethod UseDailyCall() As %Integer
{
    set date=$zdate($horolog,8)
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUDGET_BUSY") }
    set used=+$get(^PIBudget($namespace,"dailyCalls",date))
    if used>=..#DAILYCALLLIMIT {
        lock -^PIBudget($namespace,"lock")
        throw ##class(%Exception.General).%New("DAILY_CALL_LIMIT")
    }
    set ^PIBudget($namespace,"dailyCalls",date)=used+1
    lock -^PIBudget($namespace,"lock")
    quit used+1
}

/// Return a counted call when the investigation never reached the model, so quota is not consumed by refusals.
ClassMethod ReleaseDailyCall()
{
    set date=$zdate($horolog,8)
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUDGET_BUSY") }
    set used=+$get(^PIBudget($namespace,"dailyCalls",date))
    if used>0 { set ^PIBudget($namespace,"dailyCalls",date)=used-1 }
    lock -^PIBudget($namespace,"lock")
}

/// Report today's AI call usage for health displays and the investigation modal.
ClassMethod DailySnapshot() As %DynamicObject
{
    set date=$zdate($horolog,8),used=+$get(^PIBudget($namespace,"dailyCalls",date))
    quit {"date":(date),"callsUsed":(used),"callLimit":(..#DAILYCALLLIMIT)}
}

/// Convert the legacy planning ledger once at its historical 10:1 coefficient, without increasing spending authorization.
ClassMethod EnsureUsd()
{
    set entryLevel=$tlevel
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUDGET_BUSY") }
    try {
        if $get(^PIBudget($namespace,"currency"))'="USD" {
            if $get(^PIBudget($namespace,"currency"))'="" { throw ##class(%Exception.General).%New("BUDGET_CURRENCY_INVALID") }
            if $data(^PIBudget($namespace,"spentUsd"))!$data(^PIBudget($namespace,"reservedUsd"))!$data(^PIBudget($namespace,"unknownUsd")) { throw ##class(%Exception.General).%New("BUDGET_CURRENCY_INVALID") }
            if +$get(^PIBudget($namespace,"reservedCny"))'=0 { throw ##class(%Exception.General).%New("BUDGET_MIGRATION_BUSY") }
            set id=""
            for {
                set id=$order(^PIBudget($namespace,"reservation",id)) quit:id=""
                if $get(^PIBudget($namespace,"reservation",id))="OPEN" { throw ##class(%Exception.General).%New("BUDGET_MIGRATION_BUSY") }
            }
            set legacy=$data(^PIBudget($namespace,"spentCny"))!$data(^PIBudget($namespace,"reservedCny"))!$data(^PIBudget($namespace,"unknownCny"))!$data(^PIBudget($namespace,"reservation"))
            tstart
            // Archive the original monetary records in the same transaction as the currency marker and converted values.
            if legacy,'$data(^PIBudgetArchive($namespace,"CNY-v1")) { merge ^PIBudgetArchive($namespace,"CNY-v1")=^PIBudget($namespace) }
            set ^PIBudget($namespace,"spentUsd")=+$get(^PIBudget($namespace,"spentCny"))/10
            set ^PIBudget($namespace,"reservedUsd")=0,^PIBudget($namespace,"unknownUsd")=+$get(^PIBudget($namespace,"unknownCny"))/10
            set id=""
            for {
                set id=$order(^PIBudget($namespace,"reservation",id)) quit:id=""
                if $data(^PIBudget($namespace,"reservation",id,"amount")) { set ^PIBudget($namespace,"reservation",id,"amount")=^PIBudget($namespace,"reservation",id,"amount")/10 }
                if $data(^PIBudget($namespace,"reservation",id,"settledCost")) { set ^PIBudget($namespace,"reservation",id,"settledCost")=^PIBudget($namespace,"reservation",id,"settledCost")/10 }
            }
            kill ^PIBudget($namespace,"spentCny"),^PIBudget($namespace,"reservedCny"),^PIBudget($namespace,"unknownCny")
            set ^PIBudget($namespace,"currency")="USD",^PIBudget($namespace,"schemaVersion")=2
            if legacy { set ^PIBudget($namespace,"migratedAt")=$ztimestamp }
            tcommit
        }
    } catch ex {
        if $tlevel>entryLevel { trollback 1 }
        lock -^PIBudget($namespace,"lock")
        throw ex
    }
    lock -^PIBudget($namespace,"lock")
}

/// Return a consistent USD health contract shared by both web budget displays.
ClassMethod Snapshot() As %DynamicObject
{
    do ..EnsureUsd()
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUDGET_BUSY") }
    set spent=+$get(^PIBudget($namespace,"spentUsd")),unknown=+$get(^PIBudget($namespace,"unknownUsd"))
    set data={"currency":"USD","budgetUsd":(..#LIMITUSD),"estimatedUsd":(spent),"reservedUsd":(+$get(^PIBudget($namespace,"reservedUsd"))),"unknownUsageUsd":(unknown),"knownEstimateUsd":(spent-unknown)}
    lock -^PIBudget($namespace,"lock")
    quit data
}
}
