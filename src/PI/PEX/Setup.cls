Class PI.PEX.Setup Extends %RegisteredObject
{
/// Compile and register the Java operation against the built-in loopback Java Server without changing business data.
ClassMethod Install()
{
    set path=##class(PI.InstallPaths).Root()_"java/",build=$system.Util.ManagerDirectory()_"pi-review/java-build"
    if '##class(%File).Exists(path_"build.sh") { throw ##class(%Exception.General).%New("PEX_RESOURCES_MISSING") }
    // Pass fixed executable arguments individually; installed resources also work without a source checkout.
    set rc=$zf(-100,"","/bin/bash",path_"build.sh",build)
    if rc'=0 { throw ##class(%Exception.General).%New("PEX_JAVA_BUILD_FAILED") }
    set sdk=$system.Util.InstallDirectory()_"dev/java/lib/1.8/intersystems-pex-1.0.0-shaded.jar"
    set classpath=sdk_":"_build_"/pi-name-pex.jar:"_build_"/lib/icu4j-72.1.jar"
    set sc=##class(EnsLib.PEX.Utils).RegisterComponent("org.pireview.pex.NameSimilarityOperation","%Java Server",classpath,1,"PI.PEX.NameSimilarityOperation")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
}
}
