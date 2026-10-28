Class PI.Setup Extends %RegisteredObject
{
/// Initialize this project's REST applications without modifying other containers or system applications.
ClassMethod Install()
{
    new $namespace
    set $namespace="USER"
    do ##class(PI.ModelConfig).Install("","","")
    set sc=##class(Ens.Director).StopProduction(,1)
    set $namespace="%SYS"
    set p("NameSpace")="USER",p("DispatchClass")="PI.REST",p("AutheEnabled")=96
    set p("Enabled")=1,p("MatchRoles")=":%DB_USER:PIReviewRuntime"
    // Use the native site session for web pages; anonymous users may access only the login page and fixed assets.
    set p("UseCookies")=2,p("CookiePath")="/identity/",p("Timeout")=1800
    if ##class(Security.Applications).Exists("/identity") {
        set sc=##class(Security.Applications).Modify("/identity",.p)
    } else {
        set sc=##class(Security.Applications).Create("/identity",.p)
    }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    // Use existing IRIS administrator identities for management; add no editing roles to the anonymous application.
    kill p
    set p("NameSpace")="USER",p("DispatchClass")="PI.ConfigREST",p("AutheEnabled")=96,p("Enabled")=1,p("Resource")="",p("MatchRoles")=":%DB_USER"
    // Use native cookie sessions for the admin application with a 30-minute idle timeout; preserve existing IRIS user permissions.
    set p("UseCookies")=2,p("CookiePath")="/identity-admin/",p("Timeout")=1800
    if ##class(Security.Applications).Exists("/identity-admin") {
        set sc=##class(Security.Applications).Modify("/identity-admin",.p)
    } else {
        set sc=##class(Security.Applications).Create("/identity-admin",.p)
    }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    // Tests need a separate physical globals database to prevent interference between interoperability temporary mappings and monitoring.
    if '##class(Config.Databases).Exists("PI_TEST_DATA") {
        set directory="/durable/iris/pi-test-data/"
        do ##class(%Library.File).CreateDirectory(directory)
        set sc=##class(SYS.Database).CreateDatabase(directory,8,8192,0,"%DB_USER",1)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        set db("Directory")=directory,sc=##class(Config.Databases).Create("PI_TEST_DATA",.db)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    }
    set n("Globals")="PI_TEST_DATA",n("Routines")="USER"
    if ##class(Config.Namespaces).Exists("PITEST") {
        set sc=##class(Config.Namespaces).Get("PITEST",.old)
        if old("Globals")'="PI_TEST_DATA" {
            set sc=##class(%Library.EnsembleMgr).DisableNamespace("PITEST")
            if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
            set sc=##class(Config.Namespaces).Modify("PITEST",.n)
        }
    } else {
        set sc=##class(Config.Namespaces).Create("PITEST",.n)
    }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    set sc=##class(%Library.EnsembleMgr).EnableNamespace("PITEST")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    set $namespace="USER"
    set sc=##class(Ens.Director).RecoverProduction()
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    do ##class(PI.Governance).Install()
    set sc=##class(Ens.Director).StartProduction("PI.Production")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    // Configure the Production to start with IRIS so the workflow recovers after a container restart.
    set sc=##class(Ens.Director).SetAutoStart("PI.Production")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    write "PI_SETUP_OK",!
}
}
