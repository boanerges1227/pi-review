Class PI.PackageTests Extends PI.Tests
{
/// Installed resource paths must not rely on a checkout and failed configuration must preserve the working location.
ClassMethod Run()
{
    do ..Assert(##class(%Dictionary.CompiledClass).%ExistsId("PI.InstallPaths"),"package resource resolver is installed")
    set old=$get(^PIInstall($namespace,"root")),root="/tmp/pi-review-package-test/"
    try {
        do ##class(%File).CreateDirectory(root)
        do ##class(%File).CreateDirectory(root_"web/")
        do ##class(%File).CreateDirectory(root_"data/")
        set sc=##class(%File).CopyFile("/workspace/web/index.html",root_"web/index.html",1)
        set sc=##class(%File).CopyFile("/workspace/data/source-registry.json",root_"data/source-registry.json",1)
        do ##class(PI.InstallPaths).Configure(root)
        do ..Assert(##class(PI.InstallPaths).WebRoot()=(root_"web/"),"installed assets resolve outside the checkout")
        do ..Assert(##class(PI.InstallPaths).SourceRegistryPath()=(root_"data/source-registry.json"),"installed source fixture resolves outside the checkout")
        set denied=0
        try { do ##class(PI.InstallPaths).Configure("/tmp/pi-review-missing-package/") } catch ex { set denied=1 }
        do ..Assert(denied&&(##class(PI.InstallPaths).WebRoot()=(root_"web/")),"missing resources cannot replace the working package path")
        set denied=0
        try { do ##class(PI.InstallPaths).Configure("/tmp/../workspace/") } catch ex { set denied=1 }
        do ..Assert(denied,"package root rejects parent traversal")
    } catch ex { set ^PIInstall($namespace,"root")=old throw ex }
    if old="" { kill ^PIInstall($namespace,"root") } else { set ^PIInstall($namespace,"root")=old }
    write "PACKAGE_PATH_TESTS_OK",!
}
}
