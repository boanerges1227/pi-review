Class PI.Production Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="PI.Production" TestingEnabled="true" LogGeneralTraceEvents="true">
 <Item Name="Intake" ClassName="PI.Service" PoolSize="0" Enabled="true" Foreground="false"/>
 <Item Name="IdentityProcess" ClassName="PI.Process" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="LinkReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="SeparateReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="Enrichment" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
 <Item Name="ConflictReview" ClassName="PI.Route" PoolSize="1" Enabled="true" Foreground="false"/>
</Production>
}
}
