Class PI.PackageSetup Extends %RegisteredObject
{
/// Activate copied assets without touching existing identities, cases, credentials or running productions.
ClassMethod Install(root As %String) As %Status
{
    try {
        for name="%AI.Agent","%AI.ToolMgr","%AI.RAG.VectorStore.IRIS","EnsLib.Workflow.Engine" {
            if '##class(%Dictionary.CompiledClass).%ExistsId(name) { throw ##class(%Exception.General).%New("AI_HUB_BUILD_REQUIRED") }
        }
        do ##class(PI.InstallPaths).Configure(root)
        write "PI_PACKAGE_RESOURCES_OK",!
    } catch ex { return ex.AsStatus() }
    quit 1
}

/// Initialize the dedicated USER installation after documented host-side model and gateway prerequisites are prepared.
ClassMethod Start()
{
    if $namespace'="USER" { throw ##class(%Exception.General).%New("PACKAGE_USER_NAMESPACE_REQUIRED") }
    set root=##class(PI.InstallPaths).Root()
    if '##class(%File).Exists("/source-secret/token")!'##class(%File).Exists("/gateway-secret/credentials.json") { throw ##class(%Exception.General).%New("PACKAGE_GATEWAY_PREREQUISITES_REQUIRED") }
    do ##class(PI.Setup).Install()
    // The test namespace has separate globals but reads the same installed immutable fixtures.
    new $namespace
    set $namespace="PITEST"
    do ##class(PI.InstallPaths).Configure(root)
    set $namespace="USER"
    do ##class(PI.FHIR.Setup).Install()
    do ##class(PI.MCP.Setup).InstallSource()
    do ##class(PI.MCP.Setup).InstallPublishing()
    do ##class(PI.MCP.NativeSetup).Install()
    write "PI_PACKAGE_START_OK",!
}
}
