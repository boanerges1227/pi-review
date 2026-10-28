Class PI.MCP.SourceGate Extends %RegisteredObject
{
/// Hold the namespace gate during source calls and reject new calls during maintenance.
ClassMethod Begin(timeout As %Integer = 30)
{
    lock +^PISourceData($namespace,"gate"):timeout
    if '$test { throw ##class(%Exception.General).%New("SOURCE_BUSY") }
    if $get(^PISourceData($namespace,"maintenance"))'="" {
        lock -^PISourceData($namespace,"gate")
        throw ##class(%Exception.General).%New("SOURCE_MAINTENANCE")
    }
}

/// Release the source call gate held by this process.
ClassMethod End()
{
    lock -^PISourceData($namespace,"gate")
}

/// Use a separate lock to drain direct native source requests that bypass the business client.
ClassMethod BeginInbound(timeout As %Integer = 30)
{
    lock +^PISourceData($namespace,"inboundGate"):timeout
    if '$test { throw ##class(%Exception.General).%New("SOURCE_BUSY") }
    if $get(^PISourceData($namespace,"maintenance"))'="" {
        lock -^PISourceData($namespace,"inboundGate")
        throw ##class(%Exception.General).%New("SOURCE_MAINTENANCE")
    }
}

/// Release the native source service ingress lock.
ClassMethod EndInbound()
{
    lock -^PISourceData($namespace,"inboundGate")
}

/// Wait for in-flight calls to finish before setting an owner-scoped maintenance marker.
ClassMethod EnterMaintenance(owner As %String, timeout As %Integer = 30)
{
    if owner="" { throw ##class(%Exception.General).%New("SOURCE_OWNER_REQUIRED") }
    lock +^PISourceData($namespace,"gate"):timeout
    if '$test { throw ##class(%Exception.General).%New("SOURCE_BUSY") }
    lock +^PISourceData($namespace,"inboundGate"):timeout
    if '$test { lock -^PISourceData($namespace,"gate") throw ##class(%Exception.General).%New("SOURCE_BUSY") }
    try {
        set existing=$get(^PISourceData($namespace,"maintenance"))
        if (existing'="")&&(existing'=owner) { throw ##class(%Exception.General).%New("SOURCE_MAINTENANCE") }
        set ^PISourceData($namespace,"maintenance")=owner
    } catch ex { lock -^PISourceData($namespace,"inboundGate") lock -^PISourceData($namespace,"gate") throw ex }
    lock -^PISourceData($namespace,"inboundGate")
    lock -^PISourceData($namespace,"gate")
}

/// Only the maintenance owner may clear the marker.
ClassMethod LeaveMaintenance(owner As %String)
{
    lock +^PISourceData($namespace,"gate"):30
    if '$test { throw ##class(%Exception.General).%New("SOURCE_BUSY") }
    try {
        if (owner="")!($get(^PISourceData($namespace,"maintenance"))'=owner) { throw ##class(%Exception.General).%New("SOURCE_OWNER_MISMATCH") }
        kill ^PISourceData($namespace,"maintenance")
    } catch ex { lock -^PISourceData($namespace,"gate") throw ex }
    lock -^PISourceData($namespace,"gate")
}
}
