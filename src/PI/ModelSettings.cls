Class PI.ModelSettings Extends %RegisteredObject
{
/// Preset protocols and endpoints without guessing account model availability; native non-compatible protocols use SDK default endpoints.
ClassMethod Presets() As %DynamicArray
{
    quit [
        {"id":"qwen","name":"Qwen","adapter":"openai","baseURL":"https://dashscope-us.aliyuncs.com/compatible-mode/v1","keyRequired":true},
        {"id":"openai","name":"OpenAI","adapter":"openai","baseURL":"https://api.openai.com/v1","keyRequired":true},
        {"id":"deepseek","name":"DeepSeek","adapter":"openai","baseURL":"https://api.deepseek.com/v1","keyRequired":true},
        {"id":"anthropic","name":"Anthropic Claude","adapter":"anthropic","baseURL":"https://api.anthropic.com","keyRequired":true},
        {"id":"gemini","name":"Google Gemini","adapter":"gemini","baseURL":"https://generativelanguage.googleapis.com","keyRequired":true},
        {"id":"ollama","name":"Ollama (local)","adapter":"openai","baseURL":"http://host.docker.internal:11434/v1","keyRequired":false},
        {"id":"custom","name":"Custom OpenAI-compatible","adapter":"openai","baseURL":"","keyRequired":true}
    ]
}

/// Allow only preset providers; the browser cannot specify arbitrary SDK classes or protocols.
ClassMethod Preset(id As %String) As %DynamicObject
{
    set presets=..Presets()
    for i=0:1:presets.%Size()-1 { set p=presets.%Get(i) if p.id=id { return p } }
    throw ##class(%Exception.General).%New("INVALID_MODEL_PRESET")
}

/// Build native configuration names solely from this project's namespace and controlled IDs.
ClassMethod FQN(id As %String) As %String
{
    if id="default" { quit ##class(PI.ModelConfig).BaseName() }
    if (id'?1"p"1.N)!($length(id)>15) { throw ##class(%Exception.General).%New("INVALID_MODEL_PROFILE") }
    quit ##class(PI.ModelConfig).BaseName()_"_"_id
}

/// Creation and editing require existing IRIS configuration and Wallet admin permissions; grant no editing roles to the anonymous workbench.
ClassMethod RequireAdmin()
{
    if '$system.Security.Check("%Admin_ConfigStore","USE") { throw ##class(%Exception.General).%New("FORBIDDEN") }
    if '$system.Security.Check("%Admin_Wallet","USE") { throw ##class(%Exception.General).%New("FORBIDDEN") }
}

/// Read safe metadata without resolving Wallet references or returning secret:// references or keys to the browser.
ClassMethod Row(id As %String) As %DynamicObject
{
    set fqn=..FQN(id)
    if id'="default",'$data(^PIModels($namespace,"profiles",id)) { throw ##class(%Exception.General).%New("MODEL_PROFILE_NOT_FOUND") }
    set sc=##class(%ConfigStore.Configuration).Get(fqn,.cfg)
    if $system.Status.IsError(sc) {
        if id="default" { return {"id":"default","version":0,"label":"Default model","preset":"qwen","adapter":"openai","model":"","baseURL":"https://dashscope-us.aliyuncs.com/compatible-mode/v1","keyRequired":true,"keyStored":false,"configured":false,"rates":{},"active":true} }
        throw ##class(%Exception.General).%New("MODEL_PROFILE_NOT_FOUND")
    }
    set d=cfg.Details,meta={}
    try { set meta={}.%FromJSON(cfg.Description) } catch ex { set meta={} }
    if 'meta.%Get("piProfile",0) {
        if id'="default" { throw ##class(%Exception.General).%New("MODEL_PROFILE_NOT_FOUND") }
        set inferred=$select(d.%Get("base_url","")["dashscope":"qwen",1:"custom")
        set meta={"version":0,"preset":(inferred),"rates":{"input":2,"output":6}}
    }
    set p=..Preset(meta.%Get("preset","custom")),active=$get(^PIModels($namespace,"active"),"default")
    quit {"id":(id),"version":(meta.%Get("version",0)),"label":(cfg.DisplayName),"preset":(p.id),"adapter":(p.adapter),"model":(d.%Get("model","")),"baseURL":(d.%Get("base_url",p.baseURL)),"keyRequired":(p.keyRequired),"keyStored":(p.keyRequired&&(d.%Get("api_key","")'="")),"configured":(cfg.Enabled),"rates":(meta.%Get("rates",{})),"active":(active=id)}
}

/// Return the current selection, provider presets, and at most twenty configurations for this project.
ClassMethod Catalog() As %DynamicObject
{
    set rows=[],id="",n=0
    do rows.%Push(..Row("default"))
    for { set id=$order(^PIModels($namespace,"profiles",id)) quit:id=""  do rows.%Push(..Row(id)) set n=n+1 quit:n=20 }
    quit {"activeId":($get(^PIModels($namespace,"active"),"default")),"profiles":(rows),"presets":(..Presets()),"writesRequireAdmin":true}
}

/// Reject URL credentials, query keys, and control characters in endpoints; require HTTPS for remote endpoints.
ClassMethod ValidateEndpoint(url As %String)
{
    if ($length(url)>500)!(url="") { throw ##class(%Exception.General).%New("INVALID_MODEL_ENDPOINT") }
    set https="^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*)?$"
    set local="^http://(localhost|127[.]0[.]0[.]1|host[.]docker[.]internal)(:[0-9]{1,5})?(/[A-Za-z0-9._~!$&'()*+,;=:@%/-]*)?$"
    if '##class(%Regex.Matcher).%New(https,url).Match(),'##class(%Regex.Matcher).%New(local,url).Match() { throw ##class(%Exception.General).%New("INVALID_MODEL_ENDPOINT") }
}

/// Limit all user text and reject control characters to prevent injection into logs or native fields.
ClassMethod Text(value As %String, maximum As %Integer, allowEmpty As %Boolean = 0) As %String
{
    if (($length(value)=0)&&'allowEmpty)!($length(value)>maximum) { throw ##class(%Exception.General).%New("INVALID_MODEL_FIELD") }
    for i=1:1:$length(value) { if $ascii(value,i)<32 { throw ##class(%Exception.General).%New("INVALID_MODEL_FIELD") } }
    quit value
}

/// Treat cost inputs as user-supplied planning upper bounds; allow drafts without rates, but do not activate cloud models without them.
ClassMethod ValidateRates(rates As %DynamicObject) As %DynamicObject
{
    if '$isobject(rates) { quit {} }
    if 'rates.%IsDefined("input"),'rates.%IsDefined("output") { quit {} }
    for k="input","output" {
        if rates.%GetTypeOf(k)'="number" { throw ##class(%Exception.General).%New("INVALID_MODEL_RATES") }
        if (rates.%Get(k)<0)!(rates.%Get(k)>10000) { throw ##class(%Exception.General).%New("INVALID_MODEL_RATES") }
    }
    quit {"input":(rates.input),"output":(rates.output)}
}

/// Share the reservation lock while saving so in-flight calls cannot switch models, credentials, or rates.
ClassMethod Save(data As %DynamicObject) As %DynamicObject
{
    do ..RequireAdmin()
    set p=..Preset(data.%Get("preset","")),id=data.%Get("id","")
    if id'="" { set fqn=..FQN(id) }
    set label=..Text(data.%Get("label",""),80),model=..Text(data.%Get("model",""),200),url=..Text(data.%Get("baseURL",""),500),key=..Text(data.%Get("apiKey",""),2048,1)
    do ..ValidateEndpoint(url)
    if (p.adapter'="openai")&&(url'=p.baseURL) { throw ##class(%Exception.General).%New("MODEL_ENDPOINT_FIXED") }
    set rates=..ValidateRates(data.%Get("rates",{}))
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("MODEL_CONFIG_BUSY") }
    try {
        if $get(^PIBudget($namespace,"reservedCny"))>0 { throw ##class(%Exception.General).%New("MODEL_CONFIG_BUSY") }
        set old={},oldRef="",version=0
        if id'="" {
            set old=..Row(id),version=old.version
            if data.%Get("version",-1)'=version { throw ##class(%Exception.General).%New("CONFIG_VERSION_CONFLICT") }
            set sc=##class(%ConfigStore.Configuration).Get(..FQN(id),.existing)
            if $system.Status.IsOK(sc) { set oldRef=existing.Details.%Get("api_key","") }
            if p.keyRequired,key="",((old.baseURL'=url)!(old.preset'=p.id)) { throw ##class(%Exception.General).%New("NEW_KEY_REQUIRED") }
        } else {
            set count=0,x=""
            for { set x=$order(^PIModels($namespace,"profiles",x)) quit:x=""  set count=count+1 }
            if count>=20 { throw ##class(%Exception.General).%New("MODEL_PROFILE_LIMIT") }
            set id="p"_$increment(^PIModels($namespace,"seq"))
        }
        if id=$get(^PIModels($namespace,"active"),"default"),(('rates.%IsDefined("input"))!('rates.%IsDefined("output"))) { throw ##class(%Exception.General).%New("MODEL_RATES_REQUIRED") }
        if p.keyRequired,key="",((oldRef="")!('old.%Get("keyStored",0))) { throw ##class(%Exception.General).%New("MODEL_KEY_REQUIRED") }
        set collection="PIReview"_$namespace,secretName=collection_".Settings"_$increment(^PIModels($namespace,"secretSeq"))
        set meta={"piProfile":true,"version":(version+1),"preset":(p.id),"rates":(rates)}
        do ..WriteNative(..FQN(id),collection,secretName,key,oldRef,p,model,url,label,meta)
        if id'="default" { set ^PIModels($namespace,"profiles",id)=1 }
        do ..Audit("SAVE",id,version+1)
        set result=..Row(id)
    } catch ex { lock -^PIBudget($namespace,"lock") throw ex }
    lock -^PIBudget($namespace,"lock")
    quit result
}

/// Keep native writes within admin calls and secrets in Wallet; on failure, remove only newly created entries and preserve the old version.
ClassMethod WriteNative(fqn As %String, collection As %String, secretName As %String, key As %String, oldRef As %String, preset As %DynamicObject, model As %String, url As %String, label As %String, meta As %DynamicObject)
{
    new $namespace
    set $namespace="%SYS",created=0
    try {
        if '##class(%Wallet.Collection).Exists(collection) {
            set props={"UseResource":"PIModelUse","EditResource":"PIModelEdit"},sc=##class(%Wallet.Collection).Create(collection,props)
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_SAVE_FAILED") }
        }
        set ref=oldRef
        if (key'="")!('preset.keyRequired) {
            set value=$select(preset.keyRequired:key,1:"local-no-api-key"),props={"Usage":"CUSTOM","Secret":{"api_key":(value)}}
            set sc=##class(%Wallet.KeyValue).Create(secretName,props)
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_SAVE_FAILED") }
            set created=1,ref="secret://"_secretName_"#api_key"
        }
        set details={"model_provider":(preset.adapter),"model":(model),"base_url":(url),"api_key":(ref)}
        if ##class(%ConfigStore.Configuration).Exists(fqn) {
            set sc=##class(%ConfigStore.Configuration).Modify(fqn,details,label,meta.%ToJSON(),"PIConfigRead:U","PIConfigEdit:U",1)
        } else {
            set sc=##class(%ConfigStore.Configuration).Create("AI","LLM","",$piece(fqn,".",3),details,label,meta.%ToJSON(),"PIConfigRead:U","PIConfigEdit:U")
        }
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("MODEL_CONFIG_SAVE_FAILED") }
    } catch ex {
        if created { set sc=##class(%Wallet.KeyValue).Delete(secretName) }
        throw ##class(%Exception.General).%New("MODEL_CONFIG_SAVE_FAILED")
    }
}

/// Activation changes only the project selection; it neither resets the budget nor sends external model requests.
ClassMethod Activate(id As %String, version As %Integer) As %DynamicObject
{
    do ..RequireAdmin()
    lock +^PIBudget($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("MODEL_CONFIG_BUSY") }
    try {
        if $get(^PIBudget($namespace,"reservedCny"))>0 { throw ##class(%Exception.General).%New("MODEL_CONFIG_BUSY") }
        set row=..Row(id)
        if row.version'=version { throw ##class(%Exception.General).%New("CONFIG_VERSION_CONFLICT") }
        if 'row.configured { throw ##class(%Exception.General).%New("MODEL_NOT_CONFIGURED") }
        if 'row.rates.%IsDefined("input")!'row.rates.%IsDefined("output") { throw ##class(%Exception.General).%New("MODEL_RATES_REQUIRED") }
        // Create only the protocol client to validate format; do not call ListModels or Chat or spend model budget.
        set client={"api_key":"unused"}
        if row.adapter="openai" { set client."base_url"=row.baseURL }
        set provider=##class(%AI.Provider).Create(row.adapter,client)
        set ^PIModels($namespace,"active")=id
        do ..Audit("ACTIVATE",id,version)
        set row.active=1
    } catch ex { lock -^PIBudget($namespace,"lock") throw ##class(%Exception.General).%New($select($extract(ex.Name,1)="<":"MODEL_FORMAT_INVALID",1:ex.Name)) }
    lock -^PIBudget($namespace,"lock")
    quit row
}

/// Snapshot rates at the start of each round; settlement must not reread configuration that may have changed.
ClassMethod Pricing() As %DynamicObject
{
    set row=..Row($get(^PIModels($namespace,"active"),"default"))
    if 'row.rates.%IsDefined("input")!'row.rates.%IsDefined("output") { throw ##class(%Exception.General).%New("MODEL_RATES_REQUIRED") }
    quit row.rates
}

/// Admin audits retain only the action, configuration ID, version, and actor; exclude keys, request bodies, and endpoint text.
ClassMethod Audit(action As %String, id As %String, version As %Integer)
{
    set n=$increment(^PIModels($namespace,"auditSeq")),^PIModels($namespace,"audit",n)={"action":(action),"profileId":(id),"version":(version),"actor":($username),"time":($zdatetime($horolog,3))}.%ToJSON()
}
}
