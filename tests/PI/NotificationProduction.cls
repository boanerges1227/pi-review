Class PI.NotificationProduction Extends Ens.Production
{
XData ProductionDefinition
{
<Production Name="PI.NotificationProduction" TestingEnabled="true">
 <Item Name="Intake" ClassName="PI.Service" PoolSize="0" Enabled="true"/>
 <Item Name="IdentityResultRelay" ClassName="PI.Notification.Relay" PoolSize="1" Enabled="true">
  <Setting Target="Adapter" Name="CallInterval">1</Setting>
 </Item>
 <Item Name="IdentityResultOutbound" ClassName="PI.Notification.Operation" PoolSize="2" Enabled="true">
  <Setting Target="Adapter" Name="HTTPServer">127.0.0.1</Setting>
  <Setting Target="Adapter" Name="HTTPPort">18894</Setting>
  <Setting Target="Adapter" Name="URL">/identity-results</Setting>
  <Setting Target="Adapter" Name="ConnectTimeout">1</Setting>
  <Setting Target="Adapter" Name="ResponseTimeout">2</Setting>
  <Setting Target="Adapter" Name="WriteTimeout">1</Setting>
  <Setting Target="Host" Name="RetrySeconds">2</Setting>
  <Setting Target="Host" Name="MaxAttempts">3</Setting>
 </Item>
</Production>
}
}
