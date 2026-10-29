Class PI.VisitStatsHTTP Extends PI.REST
{
/// Simulate a configured public origin only within this request's worker process, then always restore it.
ClassMethod LoginPage() As %Status
{
    set os=$system.Python.Import("os"),previous=$system.Util.GetEnviron("PI_PUBLIC_ORIGIN")
    do os.putenv("PI_PUBLIC_ORIGIN","https://review.example.org")
    try { set status=##super() } catch ex {
        do os.putenv("PI_PUBLIC_ORIGIN",previous)
        throw ex
    }
    do os.putenv("PI_PUBLIC_ORIGIN",previous)
    quit status
}
}
