Class PI.TraceFixtureProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="PI.TraceFixtureProduction" TestingEnabled="true">
 <Item Name="InvestigationTrace" ClassName="PI.Trace.Intake" PoolSize="0" Enabled="true"/>
 <Item Name="InvestigationWorker" ClassName="PI.TraceFixtureWorker" PoolSize="0" Enabled="true"/>
 <Item Name="ModelTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true"/>
 <Item Name="ToolTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true"/>
 <Item Name="RunTrace" ClassName="PI.Trace.Sink" PoolSize="1" Enabled="true"/>
</Production>
}
}
