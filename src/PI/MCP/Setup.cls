Class PI.MCP.Setup Extends %RegisteredObject
{
/// Provision only the project source secret; never replace a credential on routine startup.
ClassMethod InstallSource()
{
    new $namespace
    set $namespace="%SYS"
    if '##class(Security.Resources).Exists("PIMCPUse") {
        set sc=##class(Security.Resources).Create("PIMCPUse","Use project source MCP credential","",0)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    if '##class(%Wallet.Collection).Exists("PIMCP") {
        set sc=##class(%Wallet.Collection).Create("PIMCP",{"UseResource":"PIMCPUse","EditResource":"PIModelEdit"})
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    if '##class(%Wallet.KeyValue).Exists("PIMCP.Source") {
        set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile("/source-secret/token")
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set secret=stream.Read(256)
        if $length(secret)<32 { throw ##class(%Exception.General).%New("MCP_SECRET_MISSING") }
        set sc=##class(%Wallet.KeyValue).Create("PIMCP.Source",{"Usage":"CUSTOM","Secret":(secret)})
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    set sc=##class(Security.Roles).Modify("PIReviewRuntime",{"Resources":"PIModelUse:U,PIConfigRead:U,PIMCPUse:U"})
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}
/// Create a dedicated transport identity with only MCP gateway usage and two native Type18 endpoints.
ClassMethod InstallPublishing()
{
    set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile("/gateway-secret/credentials.json")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MCP_GATEWAY_SECRET_MISSING") }
    set credentials={}.%FromJSON(stream)
    new $namespace
    set $namespace="%SYS"
    if '##class(Security.Roles).Exists("PIReviewMCPTransport") {
        set sc=##class(Security.Roles).Create("PIReviewMCPTransport","Dedicated identity-review MCP gateway","%Service_MCPGateway:U","")
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    if '##class(Security.Users).Exists("PIReviewMCPGateway") {
        set user("Roles")="PIReviewMCPTransport",user("Password")=credentials.password,user("Enabled")=1,user("ChangePassword")=0,user("FullName")="Identity review MCP transport"
        set sc=##class(Security.Users).Create("PIReviewMCPGateway",.user)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    for ns="USER","PITEST" {
        kill p
        set path=$select(ns="USER":"/mcp/identity",1:"/mcp/identity-test")
        set p("Type")=18,p("NameSpace")=ns,p("DispatchClass")="PI.MCP.Service",p("Enabled")=1,p("AutheEnabled")=64,p("UseCookies")=0,p("MatchRoles")=":%DB_USER",p("Resource")=""
        if ##class(Security.Applications).Exists(path) { set sc=##class(Security.Applications).Modify(path,.p) } else { set sc=##class(Security.Applications).Create(path,.p) }
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set $namespace=ns
        do ##class(PI.MCP.Access).Provision(credentials.%Get($select(ns="USER":"clientToken",1:"testToken")))
        set $namespace="%SYS"
    }
}
}
