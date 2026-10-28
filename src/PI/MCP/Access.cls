Class PI.MCP.Access Extends %RegisteredObject
{
/// Store token hashes only in the current namespace; do not persist plaintext.
ClassMethod Hash(token As %String) As %String
{
    quit $system.Encryption.Base64Encode($system.Encryption.SHAHash(256,token))
}

/// Clear any identity from a reused process before validating credentials under the management lock.
ClassMethod Authenticate(token As %String)
{
    kill ^||PIMCP
    if (token="")!($length(token)>512) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    set hash=..Hash(token)
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set actor=..Validate(hash)
        set ^||PIMCP("actor")=actor,^||PIMCP("hash")=hash
        set ^PIMCPAccess($namespace,"lastUsed",actor)=##class(PI.MCP.Tokens).Now()
    } catch ex { lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
}

/// Recheck expiry, revocation and case grants on every authenticated WebSocket call.
ClassMethod Check(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set actor=$get(^||PIMCP("actor")),hash=$get(^||PIMCP("hash"))
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        if (actor="")!(..Validate(hash)'=actor) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
        if (caseId'?1"c"1.N)!('$get(^PIMCPAccess($namespace,"grant",actor,caseId))) { throw ##class(%Exception.General).%New("MCP_CASE_DENIED") }
    } catch ex { lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
    set c=##class(PI.Store).Case(caseId)
    if (expectedVersion<1)!(c.version'=expectedVersion) { throw ##class(%Exception.General).%New("STALE_CASE") }
    quit c
}

/// Validate the hash index and management state on every call rather than trusting browser status.
ClassMethod Validate(hash As %String) As %String
{
    set actor=$get(^PIMCPAccess($namespace,"token",hash))
    if actor="" { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    if $data(^PIMCPAccess($namespace,"managed",actor)) {
        set meta={}.%FromJSON(^PIMCPAccess($namespace,"managed",actor))
        if (meta.hash'=hash)!(meta.revokedAtEpoch>0)!((meta.expiresAtEpoch>0)&&(meta.expiresAtEpoch<=##class(PI.MCP.Tokens).Now())) { throw ##class(%Exception.General).%New("MCP_UNAUTHORIZED") }
    }
    quit actor
}

/// Enroll the initial local credential once; later initialization must not restore a revoked value.
ClassMethod Provision(token As %String)
{
    if $length(token)<32 { throw ##class(%Exception.General).%New("MCP_TOKEN_REQUIRED") }
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        do ##class(PI.MCP.Tokens).EnrollLegacy()
        if '$data(^PIMCPAccess($namespace,"managed","local-reviewer")) {
            set hash=..Hash(token)
            set ^PIMCPAccess($namespace,"token",hash)="local-reviewer",^PIMCPAccess($namespace,"actorToken","local-reviewer")=hash
            do ##class(PI.MCP.Tokens).EnrollLegacy()
        }
    } catch ex { lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
}

/// Allow a trusted local admin script to grant cases under the shared lock, but never reauthorize a revoked identity.
ClassMethod Grant(caseId As %String)
{
    set c=##class(PI.Store).Case(caseId)
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        do ##class(PI.MCP.Tokens).EnrollLegacy()
        set hash=$get(^PIMCPAccess($namespace,"actorToken","local-reviewer")),actor=..Validate(hash)
        set ^PIMCPAccess($namespace,"grant",actor,caseId)=1
        if $data(^PIMCPAccess($namespace,"managed",actor)) {
            set meta={}.%FromJSON(^PIMCPAccess($namespace,"managed",actor)),meta.version=meta.version+1
            set ^PIMCPAccess($namespace,"managed",actor)=meta.%ToJSON()
            do ##class(PI.MCP.Tokens).Audit("GRANT",actor,meta.version)
        }
    } catch ex { lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
}
}
