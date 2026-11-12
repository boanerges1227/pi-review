Class PI.TraceFixtureTools Extends %AI.ToolSet
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="SyntheticTraceTools">
 <Tool Name="get_case_summary" Method="Summary"><Description>Read a synthetic trace fixture.</Description></Tool>
 <Tool Name="search_governance_rules" Method="Governance"><Description>Read a synthetic trace fixture policy.</Description></Tool>
</ToolSet>
}
/// Return a privacy sentinel to verify tool content never enters the new telemetry messages.
ClassMethod Summary() As %DynamicObject { quit {"text":"FIXTURE_SECRET_TOOL_CONTENT"} }
/// Return a second native tool result, without accessing real patient or policy data.
ClassMethod Governance() As %DynamicObject { quit {"text":"FIXTURE_SECRET_GOVERNANCE_CONTENT"} }
}
