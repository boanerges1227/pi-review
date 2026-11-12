Class PI.PEX.Setup Extends %RegisteredObject
{
/// Register the bundled Python operation against the built-in loopback Python Server without changing business data.
ClassMethod Install()
{
    set path=##class(PI.InstallPaths).Root()_"python/"
    if '##class(%File).Exists(path_"pi_pex.py") { throw ##class(%Exception.General).%New("PEX_RESOURCES_MISSING") }
    // Python PEX expects the module file as its extra classpath, rather than its containing directory.
    set sc=##class(EnsLib.PEX.Utils).RegisterComponent("pi_pex.NameSimilarityOperation","%Python Server",path_"pi_pex.py",1,"PI.PEX.NameSimilarityOperation")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}
}
