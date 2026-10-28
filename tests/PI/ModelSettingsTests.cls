Class PI.ModelSettingsTests Extends PI.Tests
{
/// Test only synthetic PITEST configurations and restore the original default afterward; never modify real USER keys.
ClassMethod Profiles()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.ModelSettings"),"AI settings backend exists")
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    kill ^PIModels($namespace,"active"),^PIModels($namespace,"profiles")
    set original=##class(PI.ModelSettings).Catalog(),legacy=original.profiles.%Get(0)
    set input={"id":"","version":0,"label":"Synthetic Qwen","preset":"qwen","model":"synthetic-model","baseURL":"https://dashscope-us.aliyuncs.com/compatible-mode/v1","apiKey":"synthetic-settings-key-one","rates":{"input":3,"output":9}}
    set saved=##class(PI.ModelSettings).Save(input),id=saved.id
    do ..Assert((id'="")&&(saved.version=1),"new profile is persisted with server-generated id")
    do ..Assert(saved.%ToJSON()'["synthetic-settings-key-one","save response never reveals key")
    set chosen=##class(PI.ModelSettings).Activate(id,saved.version),resolved=##class(PI.ModelConfig).Resolve()
    do ..Assert(resolved.%Get("api_key")="synthetic-settings-key-one","active profile resolves real Wallet reference")
    do ..Assert(##class(PI.ModelConfig).Name()'="AI.LLM.PIReviewPITEST","active profile uses its own native configuration")
    set input.id=id,input.version=saved.version,input.apiKey="",input.label="Renamed synthetic profile"
    set edited=##class(PI.ModelSettings).Save(input),resolved=##class(PI.ModelConfig).Resolve()
    do ..Assert(resolved.%Get("api_key")="synthetic-settings-key-one","blank key preserves previous Wallet secret")
    set denied=0
    try { set bad=##class(PI.ModelSettings).Save(input) } catch ex { set denied=(ex.Name="CONFIG_VERSION_CONFLICT") }
    do ..Assert(denied,"outdated browser edit cannot overwrite newer profile")
    set input.version=edited.version,input.apiKey="synthetic-settings-key-two",rotated=##class(PI.ModelSettings).Save(input),resolved=##class(PI.ModelConfig).Resolve()
    do ..Assert(resolved.%Get("api_key")="synthetic-settings-key-two","rotation writes new Wallet entry")
    set catalog=##class(PI.ModelSettings).Catalog()
    do ..Assert((catalog.%ToJSON()'["synthetic-settings-key-one")&&(catalog.%ToJSON()'["synthetic-settings-key-two"),"catalog omits all secret versions")
    set input.version=rotated.version,input.apiKey="",input.baseURL="https://example.invalid/v1",denied=0
    try { set bad=##class(PI.ModelSettings).Save(input) } catch ex { set denied=(ex.Name="NEW_KEY_REQUIRED") }
    do ..Assert(denied,"changed endpoint cannot silently inherit old key")
    set input.baseURL="https://dashscope-us.aliyuncs.com/compatible-mode/v1",input.version=rotated.version
    set ^PIBudget($namespace,"reservedCny")=15,denied=0
    try { set bad=##class(PI.ModelSettings).Save(input) } catch ex { set denied=(ex.Name="MODEL_CONFIG_BUSY") }
    kill ^PIBudget($namespace,"reservedCny")
    do ..Assert(denied,"in-flight investigation blocks profile mutation")
    set chosen=##class(PI.ModelSettings).Activate("default",legacy.version)
    do ..Assert(##class(PI.ModelConfig).Name()="AI.LLM.PIReviewPITEST","legacy profile and key remain switchable")
    write "MODEL_SETTINGS_PROFILES_OK",!
}

/// Require provider allowlisting and endpoint format validation; reject arbitrary native configuration names.
ClassMethod Validation()
{
    set data={"id":"","version":0,"label":"Invalid","preset":"custom","model":"test","baseURL":"http://evil.example/v1","apiKey":"synthetic-unused","rates":{}}
    set denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="INVALID_MODEL_ENDPOINT") }
    do ..Assert(denied,"remote HTTP endpoint rejected")
    set data.baseURL="https://user:secret@example.invalid/v1",denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="INVALID_MODEL_ENDPOINT") }
    do ..Assert(denied,"URL credentials cannot appear in public metadata")
    set data.baseURL="https://example.invalid/v1?key=secret",denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="INVALID_MODEL_ENDPOINT") }
    do ..Assert(denied,"URL query cannot carry a secret")
    set data.baseURL="https://example.invalid/v1",data.id="other.Config",denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="INVALID_MODEL_PROFILE") }
    do ..Assert(denied,"arbitrary Config Store name rejected")
    set data.id="",saved=##class(PI.ModelSettings).Save(data),denied=0
    try { set x=##class(PI.ModelSettings).Activate(saved.id,saved.version) } catch ex { set denied=(ex.Name="MODEL_RATES_REQUIRED") }
    do ..Assert(denied,"new cloud profile requires explicit planning rates before activation")
    set data.preset="ollama",data.label="Local Ollama",data.baseURL="http://host.docker.internal:11434/v1",data.apiKey="",data.rates={"input":0,"output":0}
    set saved=##class(PI.ModelSettings).Save(data)
    do ..Assert(saved.keyRequired=0,"local Ollama needs no real key")
    write "MODEL_SETTINGS_VALIDATION_OK",!
}

/// Settle using the round's rate snapshot instead of applying Qwen rates to every provider.
ClassMethod Pricing()
{
    kill ^PIBudget($namespace)
    set id=##class(PI.Agent).Reserve()
    do ##class(PI.Agent).Settle(id,{"total_prompt_tokens":1000,"total_completion_tokens":1000},{"input":3,"output":9})
    do ..Assert(^PIBudget($namespace,"spentCny")=0.12,"settlement uses the captured provider rates")
    kill ^PIBudget($namespace)
    write "MODEL_SETTINGS_PRICING_OK",!
}
/// Do not save active configurations as drafts with missing rates or treat local placeholder keys as cloud credentials.
ClassMethod Boundaries()
{
    set legacy=##class(PI.ModelSettings).Row("default")
    set data={"id":"default","version":(legacy.version),"label":(legacy.label),"preset":(legacy.preset),"model":(legacy.model),"baseURL":(legacy.baseURL),"rates":{}},denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="MODEL_RATES_REQUIRED") }
    do ..Assert(denied,"active configuration cannot lose required rates")
    set data={"id":"","version":0,"label":"Local boundary fixture","preset":"ollama","model":"local","baseURL":"http://host.docker.internal:11434/v1","rates":{"input":0,"output":0}}
    set saved=##class(PI.ModelSettings).Save(data)
    set data.id=saved.id,data.version=saved.version,data.preset="custom",data.baseURL="https://example.invalid/v1",data.rates={"input":1,"output":2},denied=0
    try { set x=##class(PI.ModelSettings).Save(data) } catch ex { set denied=(ex.Name="MODEL_KEY_REQUIRED")!(ex.Name="NEW_KEY_REQUIRED") }
    do ..Assert(denied,"local placeholder is not a stored cloud credential")
    kill ^PIModels($namespace,"profiles",saved.id)
    set denied=0
    try { set x=##class(PI.ModelSettings).Activate(saved.id,saved.version) } catch ex { set denied=(ex.Name="MODEL_PROFILE_NOT_FOUND") }
    do ..Assert(denied,"orphaned native config outside project index cannot be activated")
    write "MODEL_SETTINGS_BOUNDARIES_OK",!
}

/// Initialize every preset through its real native protocol client without calling ListModels or Chat.
ClassMethod PresetClients()
{
    set presets=##class(PI.ModelSettings).Presets()
    for i=0:1:presets.%Size()-1 {
        set preset=presets.%Get(i),client={"api_key":"unused"}
        if preset.adapter="openai" { set client."base_url"=$select(preset.baseURL="":"https://example.invalid/v1",1:preset.baseURL) }
        set provider=##class(%AI.Provider).Create(preset.adapter,client)
        do ..Assert($isobject(provider),"preset initializes native protocol: "_preset.id)
    }
    write "MODEL_SETTINGS_PRESETS_OK",!
}
}
