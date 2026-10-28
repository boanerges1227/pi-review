Class PI.MCPTokenTests Extends %RegisteredObject
{
/// Test the credential lifecycle in the isolated PITEST data partition and restore the publisher credential afterward.
ClassMethod Run()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_NAMESPACE_REQUIRED") }
    do ##class(PI.Tests).Assert(##class(%Dictionary.CompiledMethod).%ExistsId("PI.MCP.Tokens||Create"),"Token management must exist")
    merge saved=^PIMCPAccess($namespace)
    try {
        kill ^PIMCPAccess($namespace)
        do ##class(PI.Tests).Reset()
        set base=##class(PI.Store).Ingest(##class(PI.Tests).Input()),input=##class(PI.Tests).Input("EMR","token-case"),input.name="Alicia Chen"
        set x=##class(PI.Store).Ingest(input),c=##class(PI.Store).Case(x.caseId)
        set legacy="synthetic-legacy-token-0000000000000000"
        do ##class(PI.MCP.Access).Provision(legacy)
        do ##class(PI.MCP.Access).Grant(c.id)
        set catalog=##class(PI.MCP.Tokens).Catalog(),old=catalog.tokens.%Get(0)
        do ##class(PI.Tests).Assert((old.id="local-reviewer")&&(old.cases.%Get(0)=c.id)&&old.legacy,"legacy case ACL survives enrollment")
        set created=##class(PI.MCP.Tokens).Create({"label":"Test reader","expiresInDays":30,"cases":[(c.id)]}),row=created.item,token=created.token
        set other=##class(PI.MCP.Tokens).Create({"label":"Other reader","expiresInDays":1,"cases":[(c.id)]})
        do ##class(PI.Tests).Assert(($length(token)>40)&&(token'=other.token),"tokens have independent cryptographic randomness")
        do ##class(PI.Tests).Assert((row.version=1)&&(row.status="ACTIVE")&&(row.expiresAtEpoch>row.createdAtEpoch),"created token has version and finite lifetime")
        do ##class(PI.MCP.Access).Authenticate(token)
        set proof=##class(PI.MCP.Access).Check(c.id,c.version)
        do ##class(PI.Tests).Assert(proof.id=c.id,"created token authorizes only its explicit ACL")
        set bad=0 try { set proof=##class(PI.MCP.Access).Check("c99999",1) } catch ex { set bad=ex.Name="MCP_CASE_DENIED" }
        do ##class(PI.Tests).Assert(bad,"unknown case does not inherit another token scope")
        set catalog=##class(PI.MCP.Tokens).Catalog(),serialized=catalog.%ToJSON()
        do ##class(PI.Tests).Assert(($find(serialized,token)=0)&&($find(serialized,##class(PI.MCP.Access).Hash(token))=0),"catalog exposes neither plaintext nor digest")
        set id="",dump="" for { set id=$order(^PIMCPAccess($namespace,"managed",id)) quit:id=""  set dump=dump_^PIMCPAccess($namespace,"managed",id) }
        do ##class(PI.Tests).Assert($find(dump,token)=0,"stored metadata never retains plaintext")
        set updated=##class(PI.MCP.Tokens).Update(row.id,{"label":"No cases","version":1,"cases":[]})
        set bad=0 try { set proof=##class(PI.MCP.Access).Check(c.id,c.version) } catch ex { set bad=ex.Name="MCP_CASE_DENIED" }
        do ##class(PI.Tests).Assert(bad&&(updated.version=2),"existing connection immediately loses removed grants")
        set bad=0 try { set ignored=##class(PI.MCP.Tokens).Update(row.id,{"label":"stale","version":1,"cases":[(c.id)]}) } catch ex { set bad=ex.Name="MCP_TOKEN_VERSION_CONFLICT" }
        do ##class(PI.Tests).Assert(bad,"stale edits are rejected")
        do ##class(PI.MCP.Access).Authenticate(other.token)
        set proof=##class(PI.MCP.Access).Check(c.id,c.version)
        do ##class(PI.Tests).Assert(proof.id=c.id,"one token ACL edit does not alter another")
        set revoked=##class(PI.MCP.Tokens).Revoke(other.item.id,{"version":1})
        set bad=0 try { set proof=##class(PI.MCP.Access).Check(c.id,c.version) } catch ex { set bad=ex.Name="MCP_UNAUTHORIZED" }
        do ##class(PI.Tests).Assert(bad&&(revoked.status="REVOKED"),"revocation invalidates a previously authenticated connection")
        set bad=0 try { do ##class(PI.MCP.Access).Authenticate(other.token) } catch ex { set bad=ex.Name="MCP_UNAUTHORIZED" }
        do ##class(PI.Tests).Assert(bad&&($get(^||PIMCP("actor"))=""),"revoked authentication cannot retain process identity")
        set expired={}.%FromJSON(^PIMCPAccess($namespace,"managed",row.id)),expired.expiresAtEpoch=1,^PIMCPAccess($namespace,"managed",row.id)=expired.%ToJSON()
        set bad=0 try { do ##class(PI.MCP.Access).Authenticate(token) } catch ex { set bad=ex.Name="MCP_UNAUTHORIZED" }
        do ##class(PI.Tests).Assert(bad,"expired token cannot authenticate")
        set expired.hash="DO_NOT_PUBLISH",expired.token="DO_NOT_PUBLISH",^PIMCPAccess($namespace,"managed",row.id)=expired.%ToJSON()
        set catalog=##class(PI.MCP.Tokens).Catalog()
        do ##class(PI.Tests).Assert($find(catalog.%ToJSON(),"DO_NOT_PUBLISH")=0,"catalog uses an explicit safe field whitelist")
        set revoked=##class(PI.MCP.Tokens).Revoke("local-reviewer",{"version":(old.version)})
        do ##class(PI.MCP.Access).Provision(legacy)
        set bad=0 try { do ##class(PI.MCP.Access).Authenticate(legacy) } catch ex { set bad=ex.Name="MCP_UNAUTHORIZED" }
        do ##class(PI.Tests).Assert(bad,"routine bootstrap never resurrects a revoked token")
        set n=+$get(^PIMCPAccess($namespace,"seq"))
        for data={"label":"x","expiresInDays":0,"cases":[(c.id)]},{"label":"x","expiresInDays":366,"cases":[(c.id)]},{"label":"x","expiresInDays":1.5,"cases":[(c.id)]},{"label":"x","expiresInDays":"30","cases":[(c.id)]},{"label":"x","expiresInDays":30,"cases":["c99999"]},{"label":"x","expiresInDays":30,"cases":"c1"} {
            set bad=0 try { set ignored=##class(PI.MCP.Tokens).Create(data) } catch ex { set bad=1 }
            do ##class(PI.Tests).Assert(bad,"invalid lifetime or ACL rejected before persistence")
        }
        do ##class(PI.Tests).Assert(n=+$get(^PIMCPAccess($namespace,"seq")),"invalid creation leaves no partially created credential")
        set id="",dump="" for { set id=$order(^PIMCPAccess($namespace,"managementAudit",id)) quit:id=""  set dump=dump_^PIMCPAccess($namespace,"managementAudit",id) }
        do ##class(PI.Tests).Assert(($find(dump,token)=0)&&($find(dump,"REVOKE")>0),"management audit records actions without plaintext")
        set ns=$namespace,$namespace="USER",bad=0
        try { do ##class(PI.MCP.Access).Authenticate(token) } catch ex { set bad=ex.Name="MCP_UNAUTHORIZED" }
        set $namespace=ns
        do ##class(PI.Tests).Assert(bad,"token cannot cross namespace boundaries")
    } catch ex {
        kill ^PIMCPAccess($namespace) merge ^PIMCPAccess($namespace)=saved
        kill ^||PIMCP
        throw ex
    }
    kill ^PIMCPAccess($namespace) merge ^PIMCPAccess($namespace)=saved
    kill ^||PIMCP
    write "MCP_TOKEN_TESTS_OK ",^PITestCount,!
}
}
