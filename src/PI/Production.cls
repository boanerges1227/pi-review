Class PI.Production Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="PI.Production" TestingEnabled="true" LogGeneralTraceEvents="true">
 <Item Name="Intake" ClassName="PI.Service" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="IdentityProcess" ClassName="PI.Process" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="InvestigationTrace" ClassName="PI.Trace.Intake" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="InvestigationWorker" ClassName="PI.Trace.Worker" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="ModelTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="ToolTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="RunTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="NameSimilarityPEX" ClassName="PI.PEX.NameSimilarityOperation" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="LinkReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="SeparateReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="Enrichment" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="ConflictReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="WorkflowIntake" ClassName="PI.Workflow.Service" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="ReviewDispatch" ClassName="PI.Workflow.Dispatch" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="IdentityReview" ClassName="EnsLib.Workflow.Operation" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="IdentityResultRelay" ClassName="PI.Notification.Relay" PoolSize="1" Enabled="false" Foreground="false">
  <Setting Target="Adapter" Name="CallInterval">5</Setting>
 </Item>
 <Item Name="IdentityResultOutbound" ClassName="PI.Notification.Operation" PoolSize="1" Enabled="false" Foreground="false">
  <Setting Target="Adapter" Name="ConnectTimeout">5</Setting>
  <Setting Target="Adapter" Name="ResponseTimeout">10</Setting>
  <Setting Target="Adapter" Name="WriteTimeout">5</Setting>
  <Setting Target="Adapter" Name="URL">/identity-results</Setting>
 </Item>
</Production>
}
}
