Class PI.MCP.NativeSourceTools Extends %AI.ToolSet
{
XData Definition [ MimeType = application/xml ]
{
<ToolSet Name="NativeSyntheticSource">
  <Tool Name="verify_source_record" Method="Verify"><Description>Verify one scoped synthetic source record at its specified version.</Description></Tool>
  <Tool Name="request_enrichment" Method="Request"><Description>Create or repeat a scoped synthetic source enrichment request.</Description></Tool>
  <Tool Name="get_enrichment" Method="Fetch"><Description>Read an existing scoped synthetic enrichment request.</Description></Tool>
</ToolSet>
}

/// Validate the capability with the Wallet key and read the requested source version.
ClassMethod Verify(capability As %String) As %DynamicObject
{
    quit ##class(PI.MCP.NativeSource).Call("verify_source_record",capability,##class(%Wallet.KeyValue).GetSecretValue($select($namespace="PITEST":"PIMCP.NativeTestSigning",1:"PIMCP.SourceSigning")))
}

/// Create or idempotently retry a source enrichment request.
ClassMethod Request(capability As %String) As %DynamicObject
{
    quit ##class(PI.MCP.NativeSource).Call("request_enrichment",capability,##class(%Wallet.KeyValue).GetSecretValue($select($namespace="PITEST":"PIMCP.NativeTestSigning",1:"PIMCP.SourceSigning")))
}

/// Retrieve the bound enrichment request and any available newer version.
ClassMethod Fetch(capability As %String) As %DynamicObject
{
    quit ##class(PI.MCP.NativeSource).Call("get_enrichment",capability,##class(%Wallet.KeyValue).GetSecretValue($select($namespace="PITEST":"PIMCP.NativeTestSigning",1:"PIMCP.SourceSigning")))
}
}
