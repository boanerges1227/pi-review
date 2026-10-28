Class PI.Workflow.TaskRequest Extends EnsLib.Workflow.TaskRequest
{
Parameter RESPONSECLASSNAME = "PI.Workflow.TaskResponse";
Property CaseId As %String;
Property CaseVersion As %Integer;
Property SourceVersion As %Integer;
Property DispatchId As %String;
Storage Default
{
<Data name="TaskRequestDefaultData1">
<Subscript>"TaskRequest1"</Subscript>
<Value name="1">
<Value>CaseId</Value>
</Value>
<Value name="2">
<Value>CaseVersion</Value>
</Value>
<Value name="3">
<Value>SourceVersion</Value>
</Value>
<Value name="4">
<Value>DispatchId</Value>
</Value>
</Data>
<DefaultData>TaskRequestDefaultData1</DefaultData>
<Type>%Storage.Persistent</Type>
}

}
