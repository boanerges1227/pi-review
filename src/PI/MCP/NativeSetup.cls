Class PI.MCP.NativeSetup Extends %RegisteredObject
{
/// Provision separate signing keys, a least-privilege role and source MCP endpoints in the management namespace.
ClassMethod Install()
{
    new $namespace
    set $namespace="%SYS"
    if '##class(%Wallet.Collection).Exists("PIMCP") { throw ##class(%Exception.General).%New("SOURCE_WALLET_MISSING") }
    if '##class(%Wallet.KeyValue).Exists("PIMCP.Source") { throw ##class(%Exception.General).%New("SOURCE_BEARER_MISSING") }
    for key="PIMCP.SourceSigning","PIMCP.NativeTestSigning" {
        if '##class(%Wallet.KeyValue).Exists(key) {
            set bytes=$system.Encryption.GenCryptRand(32),secret=""
            for i=1:1:$length(bytes) { set part=$zhex($ascii(bytes,i)),secret=secret_$select($length(part)=1:"0",1:"")_part }
            set sc=##class(%Wallet.KeyValue).Create(key,{"Usage":"CUSTOM","Secret":(secret)})
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        }
    }
    if ##class(Security.Roles).Exists("PINativeSourceUse") {
        set sc=##class(Security.Roles).Get("PINativeSourceUse",.existing)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        if $get(existing("Resources"))'="PIMCPUse:RU" { throw ##class(%Exception.General).%New("SOURCE_ROLE_CONFLICT") }
    } else {
        set sc=##class(Security.Roles).Create("PINativeSourceUse","Native source Wallet access","PIMCPUse:RU","")
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    for ns="USER","PITEST" {
        set path=$select(ns="USER":"/mcp/native-source",1:"/mcp/native-source-test")
        kill p
        set p("Type")=18,p("NameSpace")=ns,p("DispatchClass")="PI.MCP.NativeSourceService",p("Enabled")=1,p("AutheEnabled")=64,p("UseCookies")=0,p("MatchRoles")=":%DB_USER:PINativeSourceUse",p("Resource")=""
        if ##class(Security.Applications).Exists(path) {
            set sc=##class(Security.Applications).Get(path,.old)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            if ($get(old("DispatchClass"))'="PI.MCP.NativeSourceService")!($get(old("NameSpace"))'=ns) { throw ##class(%Exception.General).%New("SOURCE_APPLICATION_CONFLICT") }
            set sc=##class(Security.Applications).Modify(path,.p)
        } else { set sc=##class(Security.Applications).Create(path,.p) }
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile("/gateway-secret/credentials.json")
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CREDENTIALS") }
    set credentials={}.%FromJSON(stream)
    do ..GatewayFiles("/gateway-secret/native",credentials)
    write "NATIVE_SOURCE_SETUP_OK",!
}

/// Generate gateway configuration in a private directory and refuse to overwrite conflicting files.
ClassMethod GatewayFiles(dir As %String, credentials As %DynamicObject)
{
    // The installer runs in %SYS, while the file-writing helper is deployed in the USER namespace.
    new $namespace
    set $namespace="USER"
    if '$isobject(credentials) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CREDENTIALS") }
    set password=credentials.%Get("password","")
    if ($length(password)<24)!($translate(password,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!")'="") { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CREDENTIALS") }
    if '##class(%File).DirectoryExists(dir) { if '##class(%File).CreateDirectory(dir) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_DIRECTORY") } }
    if '##class(%File).SetAttributes(dir,448,.rc) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_DIRECTORY") }
    set path=dir_"/source-shared.toml",nl=$char(10),port=52788
    set text="[mcp]"_nl_"transport = ""http"""_nl_"host = ""127.0.0.1"""_nl_"port = "_port_nl_"base_route = ""/mcp"""_nl_"allowed_hosts = [""127.0.0.1"", ""localhost""]"_nl_"allowed_origins = []"_nl_nl_"[[iris]]"_nl_"name = ""identity"""_nl_"server = {host=""127.0.0.1"",port=1972,username=""PIReviewMCPGateway"",password="""_password_"""}"_nl_"pool = {min=0,max=1}"_nl_"endpoints = [{path=""/mcp/native-source""},{path=""/mcp/native-source-test""}]"_nl_nl_"[logging]"_nl_"level = ""warn"""_nl_"output = ""stderr"""_nl
    if ##class(%File).Exists(path) {
        set old=##class(%Stream.FileCharacter).%New(),sc=old.LinkToFile(path)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CONFIG") }
        if old.Read(8192)'=text { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CONFLICT") }
    } else { do ##class(PI.MCP.NativeBootstrap).WriteNew(path,text) }
    if '##class(%File).SetAttributes(path,384,.rc) { throw ##class(%Exception.General).%New("NATIVE_GATEWAY_CONFIG") }
}

}
