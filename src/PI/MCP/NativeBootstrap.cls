Class PI.MCP.NativeBootstrap Extends %RegisteredObject
{
/// Create an initialization directory accessible only to its owner.
ClassMethod PrivateDirectory(path As %String)
{
    if '##class(%File).DirectoryExists(path) { if '##class(%File).CreateDirectory(path) { throw ##class(%Exception.General).%New("BOOTSTRAP_DIRECTORY") } }
    if '##class(%File).SetAttributes(path,448,.rc) { throw ##class(%Exception.General).%New("BOOTSTRAP_DIRECTORY") }
}

/// Create a new file in a private directory without overwriting existing credentials.
ClassMethod WriteNew(path As %String, value As %String)
{
    lock +^PISourceData($namespace,"bootstrapFile",path):5
    if '$test { throw ##class(%Exception.General).%New("BOOTSTRAP_BUSY") }
    set temporary=path_".tmp-"_$translate($system.Util.CreateGUID(),"{}-")
    try {
        if ##class(%File).Exists(path) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE_EXISTS") }
        set output=##class(%Stream.FileCharacter).%New(),sc=output.LinkToFile(temporary)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE") }
        set sc=output.Write(value)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE") }
        set sc=output.%Save()
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE") }
        if '##class(%File).SetAttributes(temporary,384,.rc) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE") }
        // Write the complete file and set permissions before renaming to avoid incomplete final files.
        kill output
        if ##class(%File).Exists(path) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE_EXISTS") }
        if '##class(%File).Rename(temporary,path) { throw ##class(%Exception.General).%New("BOOTSTRAP_FILE") }
    } catch ex { do ##class(%File).Delete(temporary) lock -^PISourceData($namespace,"bootstrapFile",path) throw ex }
    lock -^PISourceData($namespace,"bootstrapFile",path)
}

/// Generate lowercase hexadecimal values using secure IRIS randomness.
ClassMethod RandomHex(size As %Integer = 32) As %String
{
    if (size<24)!(size>64) { throw ##class(%Exception.General).%New("BOOTSTRAP_RANDOM_SIZE") }
    set bytes=$system.Encryption.GenCryptRand(size),value=""
    for i=1:1:$length(bytes) { set part=$zhex($ascii(bytes,i)),value=value_$select($length(part)=1:"0",1:"")_part }
    quit $zconvert(value,"L")
}

/// Generate source and gateway credentials on first deployment; preserve existing values on repeat deployment.
ClassMethod Provision()
{
    new $namespace
    set $namespace="USER"
    do ..PrivateDirectory("/source-secret")
    do ..PrivateDirectory("/gateway-secret")
    if '##class(%File).Exists("/source-secret/token") { do ..WriteNew("/source-secret/token",..RandomHex()) }
    do ##class(PI.MCP.Setup).InstallSource()
    set path="/gateway-secret/credentials.json"
    if '##class(%File).Exists(path) {
        set credentials={"password":("Pi9!"_..RandomHex(24)),"clientToken":(..RandomHex()),"testToken":(..RandomHex())}
        do ..WriteNew(path,credentials.%ToJSON())
    }
    set stream=##class(%Stream.FileCharacter).%New(),sc=stream.LinkToFile(path)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("BOOTSTRAP_CREDENTIALS") }
    set credentials={}.%FromJSON(stream),password=credentials.%Get("password","")
    if ($length(password)<24)!($translate(password,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!")'="")!($length(credentials.%Get("clientToken",""))<32)!($length(credentials.%Get("testToken",""))<32) { throw ##class(%Exception.General).%New("BOOTSTRAP_CREDENTIALS") }
    for which="user","test" {
        set port=$select(which="user":52785,1:52786),endpoint=$select(which="user":"/mcp/identity",1:"/mcp/identity-test"),target=$select(which="user":"/gateway-secret/gateway.toml",1:"/gateway-secret/gateway-test.toml"),nl=$char(10)
        set q=$char(34)
        set text="[mcp]"_nl_"transport = "_q_"http"_q_nl_"host = "_q_"0.0.0.0"_q_nl_"port = "_port_nl_"base_route = "_q_"/mcp"_q_nl
        set text=text_"allowed_hosts = ["_q_"127.0.0.1"_q_", "_q_"localhost"_q_"]"_nl_"allowed_origins = ["_q_"http://127.0.0.1:"_port_q_", "_q_"http://localhost:"_port_q_"]"_nl_nl
        set text=text_"[[iris]]"_nl_"name = "_q_"identity"_q_nl_"server = {host="_q_"127.0.0.1"_q_",port=1972,username="_q_"PIReviewMCPGateway"_q_",password="_q_password_q_"}"_nl
        set text=text_"pool = {min=0,max=1}"_nl_"endpoints = [{path="_q_endpoint_q_"}]"_nl_nl_"[logging]"_nl_"level = "_q_"warn"_q_nl_"output = "_q_"stderr"_q_nl

        if '##class(%File).Exists(target) { do ..WriteNew(target,text) }
    }
    do ##class(PI.MCP.Setup).InstallPublishing()
    do ##class(PI.MCP.NativeSetup).Install()
    do ..PrivateDirectory("/gateway-secret/clients")
    for which="user","test" {
        set port=$select(which="user":52785,1:52786),token=credentials.%Get($select(which="user":"clientToken",1:"testToken")),target="/gateway-secret/clients/"_which_".json",client={"url":("http://127.0.0.1:"_port_"/mcp"),"token":(token)}
        if '##class(%File).Exists(target) { do ..WriteNew(target,client.%ToJSON()) }
    }
    write "NATIVE_BOOTSTRAP_OK",!
}

}
