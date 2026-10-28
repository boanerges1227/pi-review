Class PI.FHIR.Setup Extends %RegisteredObject
{
/// Install only this project's dedicated local FHIR endpoint and refuse to replace another application.
ClassMethod Install()
{
    new $namespace
    set $namespace="%SYS",name="/identity-fhir"
    if ##class(Security.Applications).Exists(name) {
        set sc=##class(Security.Applications).Get(name,.existing)
        if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
        if existing("DispatchClass")'="PI.FHIR.REST" { throw ##class(%Exception.General).%New("FHIR_APPLICATION_CONFLICT") }
    }
    set p("NameSpace")="USER",p("DispatchClass")="PI.FHIR.REST",p("AutheEnabled")=64,p("Enabled")=1,p("MatchRoles")=":%DB_USER:PIReviewRuntime"
    if ##class(Security.Applications).Exists(name) { set sc=##class(Security.Applications).Modify(name,.p) } else { set sc=##class(Security.Applications).Create(name,.p) }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    write "PI_FHIR_SETUP_OK",!
}
}
