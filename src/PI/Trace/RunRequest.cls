Class PI.Trace.RunRequest Extends Ens.Request
{
/// Carry server-selected identifiers only; prompts and provider settings stay outside persistent messages.
Property CaseId As %String(MAXLEN = 128);
Property RunId As %Integer;
}
