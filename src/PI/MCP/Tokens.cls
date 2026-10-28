Class PI.MCP.Tokens Extends %RegisteredObject
{
/// Calculate expiration using UTC seconds to avoid host and browser time zone differences.
ClassMethod Now() As %Integer
{
    set stamp=$ztimestamp
    quit (($piece(stamp,",",1)-47117)*86400)+$piece(stamp,",",2)
}

/// Enroll script-created legacy credentials using hashes only and preserve existing case grants.
ClassMethod EnrollLegacy()
{
    set id="local-reviewer",hash=$get(^PIMCPAccess($namespace,"actorToken",id))
    if (hash="")!$data(^PIMCPAccess($namespace,"managed",id)) { quit }
    set ^PIMCPAccess($namespace,"managed",id)={"id":(id),"label":"Local reviewer (legacy)","hash":(hash),"version":1,"createdAtEpoch":0,"expiresAtEpoch":0,"revokedAtEpoch":0,"legacy":true}.%ToJSON()
}

/// Return only approved fields in listings; never expose hashes, unknown extensions or full credentials to the browser.
ClassMethod Row(id As %String) As %DynamicObject
{
    if '$data(^PIMCPAccess($namespace,"managed",id)) { throw ##class(%Exception.General).%New("MCP_TOKEN_NOT_FOUND") }
    set meta={}.%FromJSON(^PIMCPAccess($namespace,"managed",id)),cases=[],c="",status="ACTIVE"
    if meta.revokedAtEpoch>0 { set status="REVOKED" } elseif (meta.expiresAtEpoch>0)&&(meta.expiresAtEpoch<=..Now()) { set status="EXPIRED" }
    for { set c=$order(^PIMCPAccess($namespace,"grant",id,c)) quit:c=""  if $get(^PIMCPAccess($namespace,"grant",id,c)) { do cases.%Push(c) } }
    quit {"id":(id),"label":(meta.label),"version":(meta.version),"createdAtEpoch":(meta.createdAtEpoch),"expiresAtEpoch":(meta.expiresAtEpoch),"revokedAtEpoch":(meta.revokedAtEpoch),"lastUsedAtEpoch":(+$get(^PIMCPAccess($namespace,"lastUsed",id))),"status":(status),"legacy":(meta.legacy),"cases":(cases)}
}

/// Allow only native admins to read credential metadata; use the same namespace lock for listings and changes.
ClassMethod Catalog() As %DynamicObject
{
    do ##class(PI.ModelSettings).RequireAdmin()
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        do ..EnrollLegacy()
        set rows=[],id=""
        for { set id=$order(^PIMCPAccess($namespace,"managed",id)) quit:id=""  do rows.%Push(..Row(id)) }
        set result={"tokens":(rows),"namespace":($namespace),"endpoint":"http://127.0.0.1:52785/mcp"}
    } catch ex { lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
    quit result
}

/// Validate label type, length and control characters without coercing objects or numbers.
ClassMethod Label(data As %DynamicObject) As %String
{
    if data.%GetTypeOf("label")'="string" { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") }
    set label=data.label
    if ($length($zstrip(label,"<>W"))=0)!($length(label)>80) { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") }
    for i=1:1:$length(label) { if ($ascii(label,i)<32)!($ascii(label,i)=127) { throw ##class(%Exception.General).%New("INVALID_MCP_LABEL") } }
    quit label
}

/// Accept at most 50 existing case IDs as strings, deduplicate them, and treat an empty array as no case access.
ClassMethod Cases(data As %DynamicObject) As %DynamicArray
{
    if data.%GetTypeOf("cases")'="array" { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
    set input=data.cases,result=[]
    if input.%Size()>50 { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
    for i=0:1:input.%Size()-1 {
        if input.%GetTypeOf(i)'="string" { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        set id=input.%Get(i)
        if '##class(%Regex.Matcher).%New("^c[1-9][0-9]*$",id).Match() { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        if '$data(^PIData($namespace,"case",id)) { throw ##class(%Exception.General).%New("INVALID_MCP_CASES") }
        if '$data(seen(id)) { set seen(id)=1 do result.%Push(id) }
    }
    quit result
}

/// Create a high-entropy credential and persist only its hash; commit identity, case ACL and audit together or roll back.
ClassMethod Create(data As %DynamicObject) As %DynamicObject
{
    do ##class(PI.ModelSettings).RequireAdmin()
    set label=..Label(data),cases=..Cases(data)
    if data.%GetTypeOf("expiresInDays")'="number" { throw ##class(%Exception.General).%New("INVALID_MCP_EXPIRY") }
    set days=data.expiresInDays
    if (days<1)!(days>365)!(days\1'=days) { throw ##class(%Exception.General).%New("INVALID_MCP_EXPIRY") }
    set token="pi_mcp_"_$translate($system.Encryption.Base64Encode($system.Encryption.GenCryptRand(32)),"+/=","-_"),hash=##class(PI.MCP.Access).Hash(token)
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        set id="t"_$increment(^PIMCPAccess($namespace,"seq")),now=..Now()
        set meta={"id":(id),"label":(label),"hash":(hash),"version":1,"createdAtEpoch":(now),"expiresAtEpoch":(now+(days*86400)),"revokedAtEpoch":0,"legacy":false}
        set ^PIMCPAccess($namespace,"managed",id)=meta.%ToJSON(),^PIMCPAccess($namespace,"token",hash)=id,^PIMCPAccess($namespace,"actorToken",id)=hash
        do ..WriteCases(id,cases),..Audit("CREATE",id,1)
        set result={"item":(..Row(id)),"token":(token)}
        tcommit
    } catch ex { trollback 1 lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
    quit result
}

/// Require the current integer version for updates and revocation to prevent concurrent admin overwrites.
ClassMethod Current(id As %String, data As %DynamicObject) As %DynamicObject
{
    if '$data(^PIMCPAccess($namespace,"managed",id)) { throw ##class(%Exception.General).%New("MCP_TOKEN_NOT_FOUND") }
    set meta={}.%FromJSON(^PIMCPAccess($namespace,"managed",id))
    if (data.%GetTypeOf("version")'="number")||(data.%Get("version",0)'=meta.version) { throw ##class(%Exception.General).%New("MCP_TOKEN_VERSION_CONFLICT") }
    if meta.revokedAtEpoch>0 { throw ##class(%Exception.General).%New("MCP_TOKEN_REVOKED") }
    quit meta
}

/// Update the label and complete case grants without extending expiration or returning the previous token.
ClassMethod Update(id As %String, data As %DynamicObject) As %DynamicObject
{
    do ##class(PI.ModelSettings).RequireAdmin()
    set label=..Label(data),cases=..Cases(data)
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        do ..EnrollLegacy()
        set meta=..Current(id,data),meta.label=label,meta.version=meta.version+1
        set ^PIMCPAccess($namespace,"managed",id)=meta.%ToJSON()
        do ..WriteCases(id,cases),..Audit("UPDATE",id,meta.version)
        set result=..Row(id)
        tcommit
    } catch ex { trollback 1 lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
    quit result
}

/// Retain metadata and audit after revocation, delete the authentication index and ACL, and revalidate existing connections on each call.
ClassMethod Revoke(id As %String, data As %DynamicObject) As %DynamicObject
{
    do ##class(PI.ModelSettings).RequireAdmin()
    lock +^PIMCPAccess($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    tstart
    try {
        do ..EnrollLegacy()
        set meta=..Current(id,data),meta.revokedAtEpoch=..Now(),meta.version=meta.version+1
        set ^PIMCPAccess($namespace,"managed",id)=meta.%ToJSON()
        kill ^PIMCPAccess($namespace,"token",meta.hash),^PIMCPAccess($namespace,"grant",id)
        do ..Audit("REVOKE",id,meta.version)
        set result=..Row(id)
        tcommit
    } catch ex { trollback 1 lock -^PIMCPAccess($namespace,"lock") throw ex }
    lock -^PIMCPAccess($namespace,"lock")
    quit result
}

/// Replace the case ACL under the caller's management lock and transaction; token identities do not share grants.
ClassMethod WriteCases(id As %String, cases As %DynamicArray)
{
    kill ^PIMCPAccess($namespace,"grant",id)
    for i=0:1:cases.%Size()-1 { set ^PIMCPAccess($namespace,"grant",id,cases.%Get(i))=1 }
}

/// Keep admin audit separate from tool audit and record only safe actions, identities and versions, never request bodies or hashes.
ClassMethod Audit(action As %String, id As %String, version As %Integer)
{
    set n=$increment(^PIMCPAccess($namespace,"managementAuditSeq"))
    set ^PIMCPAccess($namespace,"managementAudit",n)={"action":(action),"tokenId":(id),"version":(version),"actor":($username),"occurredAtEpoch":(..Now())}.%ToJSON()
}
}
