Class PI.MCP.ReadTools Extends %AI.ToolSet [ DependsOn = (PI.MCP.ReadPolicy, PI.MCP.ReadAudit) ]
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="ReadonlyIdentityReview">
  <Policies><Authorization Class="PI.MCP.ReadPolicy"/><Audit Class="PI.MCP.ReadAudit"/></Policies>
  <Tool Name="review_case" Method="ReviewCase"><Description>Read one authorized synthetic identity case at expectedVersion. No mutation or investigation.</Description></Tool>
  <Tool Name="review_evidence" Method="ReviewEvidence"><Description>Read bounded evidence for an authorized case at expectedVersion.</Description></Tool>
  <Tool Name="review_run_trace" Method="ReviewRunTrace"><Description>Read bounded agent and MCP execution traces for an authorized case at expectedVersion.</Description></Tool>
</ToolSet>
}

/// Revalidate access inside the method as well as native policy; do not start an investigation context.
ClassMethod ReviewCase(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    set c=##class(PI.MCP.Access).Check(caseId,expectedVersion)
    quit {"id":(c.id),"version":(c.version),"status":(c.status),"synthetic":true,"incoming":(c.incoming),"candidates":(c.candidates),"result":(c.%Get("result",{}))}
}

/// Bound evidence by serialized bytes and return an explicit continuation indicator instead of silent overflow.
ClassMethod ReviewEvidence(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=##class(PI.MCP.Access).Check(caseId,expectedVersion),detail=##class(PI.Store).Detail(caseId),items=[],truncated=0,bytes=0
        for i=0:1:detail.evidence.%Size()-1 {
            set e=detail.evidence.%Get(i),bytes=bytes+$length($zconvert(e.%ToJSON(),"O","UTF8"))
            if (items.%Size()>=20)!(bytes>24000) { set truncated=1 quit }
            do items.%Push(e)
        }
        set result={"caseId":(caseId),"version":(c.version),"evidence":(items),"truncated":(truncated)}
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit result
}

/// Return only bounded operational traces; no model configuration, credentials, or writable tools are exposed.
ClassMethod ReviewRunTrace(caseId As %String, expectedVersion As %Integer) As %DynamicObject
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=##class(PI.MCP.Access).Check(caseId,expectedVersion),detail=##class(PI.Store).Detail(caseId),runs=[],mcp=[],bytes=0,truncated=0
        for i=detail.runs.%Size()-1:-1:0 {
            set item=detail.runs.%Get(i),bytes=bytes+$length(item.%ToJSON())
            if (runs.%Size()>=10)!(bytes>20000) { set truncated=1 quit }
            do runs.%Push(item)
        }
        for i=detail.mcpTrace.%Size()-1:-1:0 {
            set item=detail.mcpTrace.%Get(i),bytes=bytes+$length(item.%ToJSON())
            if (mcp.%Size()>=30)!(bytes>24000) { set truncated=1 quit }
            do mcp.%Push(item)
        }
        set result={"caseId":(caseId),"version":(c.version),"runs":(runs),"mcpTrace":(mcp),"truncated":(truncated)}
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit result
}
}
