Class PI.Trace.Ack Extends Ens.Response
{
/// Acknowledge metadata acceptance without echoing model or tool content.
Property Accepted As %Boolean;
Property TraceId As %String(MAXLEN = 64);
Property NativeSessionId As %String(MAXLEN = 64);
}
