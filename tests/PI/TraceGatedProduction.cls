Class PI.TraceGatedProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="PI.TraceGatedProduction" TestingEnabled="true">
 <Item Name="InvestigationTrace" ClassName="PI.Trace.Intake" PoolSize="0" Enabled="true"/>
 <Item Name="InvestigationWorker" ClassName="PI.Trace.Worker" PoolSize="0" Enabled="true"/>
 <Item Name="ModelTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true"/>
 <Item Name="ToolTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true"/>
 <Item Name="RunTrace" ClassName="PI.TraceGatedSink" PoolSize="1" Enabled="true"/>
</Production>
}
}
