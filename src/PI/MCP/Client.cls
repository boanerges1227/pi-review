Class PI.MCP.Client Extends %RegisteredObject
{
/// Call the source through the native IRIS MCP gateway and reject new requests during maintenance.
ClassMethod Call(c As %DynamicObject, record As %DynamicObject, action As %String, task As %DynamicObject = "") As %DynamicObject
{
    do ##class(PI.MCP.SourceGate).Begin(30)
    try { set result=##class(PI.MCP.NativeClient).Call(c,record,action,task) } catch ex { do ##class(PI.MCP.SourceGate).End() throw ex }
    do ##class(PI.MCP.SourceGate).End()
    quit result
}

/// Record source call traces without access tokens.
ClassMethod Trace(c As %DynamicObject, run As %Integer, callId As %Integer, action As %String, outcome As %String, seconds As %Numeric)
{
    do ##class(PI.MCP.NativeClient).Trace(c,run,callId,action,outcome,seconds)
}
}
