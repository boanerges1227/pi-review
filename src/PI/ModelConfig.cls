Class PI.ModelConfig Extends %RegisteredObject
{
/// Derive names from the server namespace; neither the model nor the browser may supply them.
ClassMethod BaseName() As %String
{
    quit "AI.LLM.PIReview"_$namespace
}

/// Only an authenticated administrator can change the selection; retain the original default configuration when none is selected.
ClassMethod Name() As %String
{
    set id=$get(^PIModels($namespace,"active"),"default")
    if id="default" { quit ..BaseName() }
    if (id'?1"p"1.N)!('$data(^PIModels($namespace,"profiles",id))) { throw ##class(%Exception.General).%New("MODEL_PROFILE_NOT_FOUND") }
    quit ..BaseName()_"_"_id
}

/// Bind sessions to the configuration version so endpoint or key changes cannot reuse stale factual context.
ClassMethod Revision() As %Integer
{
    set row=##class(PI.ModelSettings).Row($get(^PIModels($namespace,"active"),"default"))
    quit row.version
}

/// Write to Wallet on initial installation or explicit key rotation; idempotent startup must not overwrite keys repeatedly.
ClassMethod Install(apiKey As %String, baseURL As %String, model As %String)
{
    set suffix=$namespace,fqn=..BaseName(),collection="PIReview"_suffix
    new $namespace
    set $namespace="%SYS"
    set sc=##class(%ConfigStore.DescriptorManager).RebuildRegistry()
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    if ##class(%ConfigStore.Configuration).Exists(fqn) {
        set sc=##class(%ConfigStore.Configuration).Get(fqn,.existing)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_UNAVAILABLE") }
        set existing.ReadResource="PIConfigRead:U",existing.EditResource="PIConfigEdit:U",sc=existing.%Save()
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_PERMISSION_FAILED") }
        quit
    }
    for res="PIModelUse","PIModelEdit","PIConfigRead","PIConfigEdit" {
        if '##class(Security.Resources).Exists(res) {
            set sc=##class(Security.Resources).Create(res,"Patient identity review model configuration","",0)
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        }
    }
    if '##class(Security.Roles).Exists("PIReviewRuntime") {
        set sc=##class(Security.Roles).Create("PIReviewRuntime","Read named AI configuration and use model secret","PIModelUse:U,PIConfigRead:U","")
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    if (apiKey="")!(baseURL="")!(model="") { quit }
    if '##class(%Wallet.Collection).Exists(collection) {
        set p={"UseResource":"PIModelUse","EditResource":"PIModelEdit"}
        set sc=##class(%Wallet.Collection).Create(collection,p)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    if '##class(%Wallet.KeyValue).Exists(collection_".Model") {
        set p={"Usage":"CUSTOM","Secret":{"api_key":(apiKey)}}
        set sc=##class(%Wallet.KeyValue).Create(collection_".Model",p)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    set details={"model_provider":"openai","model":(model),"base_url":(baseURL),"api_key":("secret://"_collection_".Model#api_key")}
    set sc=##class(%ConfigStore.Configuration).Create("AI","LLM","","PIReview"_suffix,details,"Patient identity model","Synthetic contest application","PIConfigRead:U","PIConfigEdit:U")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}

/// Resolve Wallet references through native configuration; suppress raw exceptions to prevent SDK request configuration leaks.
ClassMethod Resolve() As %DynamicObject
{
    set fqn=..Name()
    try {
        set sc=##class(%ConfigStore.Configuration).Get(fqn,.cfg)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_UNAVAILABLE") }
        if 'cfg.Enabled { throw ##class(%Exception.General).%New("MODEL_CONFIG_UNAVAILABLE") }
        set sc=##class(%ConfigStore.Configuration).GetDetails(fqn,.properties,1,1)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_UNAVAILABLE") }
        return properties
    } catch ex { throw ##class(%Exception.General).%New("MODEL_CONFIG_UNAVAILABLE") }
}

/// Place HTTP timeouts in native http_config; the factory creates a client without sending a model request.
ClassMethod Provider(Output model As %String) As %AI.Provider
{
    set config=..Resolve(),model=config.%Get("model","")
    set adapter=config.%Get("model_provider","openai"),client={"api_key":(config.%Get("api_key","")),"http_config":{"request_timeout_secs":110,"connect_timeout_secs":10}}
    if adapter="openai" { set client."base_url"=config.%Get("base_url","") }
    quit ##class(%AI.Provider).Create(adapter,client)
}

/// Expose only nonsensitive health fields; never resolve or return keys.
ClassMethod Public() As %DynamicObject
{
    set fqn=..Name(),safe={"configName":(fqn),"configured":false,"secretStore":"IRIS Wallet","model":""}
    try {
        set sc=##class(%ConfigStore.Configuration).Get(fqn,.cfg)
        if $system.Status.IsOK(sc) { set safe.configured=cfg.Enabled,safe.model=cfg.Details.%Get("model","") }
    } catch ex { }
    quit safe
}
}
