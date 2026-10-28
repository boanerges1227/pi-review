Class PI.InstallPaths Extends %RegisteredObject
{
/// Configure an administrator-supplied absolute package root only after both required resource families exist.
ClassMethod Configure(root As %String)
{
    if ($extract(root,1)'="/")!(root["..")!($length(root)>1024) { throw ##class(%Exception.General).%New("PACKAGE_PATH_INVALID") }
    if $extract(root,*)'="/" { set root=root_"/" }
    if '##class(%File).Exists(root_"web/index.html")!'##class(%File).Exists(root_"data/source-registry.json") { throw ##class(%Exception.General).%New("PACKAGE_RESOURCES_MISSING") }
    set ^PIInstall($namespace,"root")=root
}

/// Prefer the installed resource root; development Compose retains its fixed readonly checkout mount.
ClassMethod Root() As %String
{
    quit $get(^PIInstall($namespace,"root"),"/workspace/")
}

/// Resolve static files beneath the server-selected root; callers still supply only fixed asset names.
ClassMethod WebRoot() As %String
{
    quit ..Root()_"web/"
}

/// Resolve the synthetic source fixture independently of the host checkout layout.
ClassMethod SourceRegistryPath() As %String
{
    quit ..Root()_"data/source-registry.json"
}
}
