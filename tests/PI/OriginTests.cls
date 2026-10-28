Class PI.OriginTests Extends PI.Tests
{
/// A configured HTTPS demo origin must work behind a proxy without accepting attacker-controlled origins.
ClassMethod Run()
{
    do ..Assert(##class(PI.REST).OriginAllowed("https://review.example.org","127.0.0.1:52784","https://review.example.org"),"explicit public HTTPS origin is accepted")
    do ..Assert('##class(PI.REST).OriginAllowed("https://review.example.org.evil.invalid","127.0.0.1:52784","https://review.example.org"),"lookalike origin is rejected")
    do ..Assert('##class(PI.REST).OriginAllowed("https://evil.invalid","review.example.org","https://review.example.org"),"foreign origin is rejected")
    do ..Assert(##class(PI.REST).OriginAllowed("http://127.0.0.1:52784","127.0.0.1:52784",""),"local development origin remains valid")
    do ..Assert('##class(PI.REST).OriginAllowed("null","127.0.0.1:52784",""),"opaque browser origin is rejected")
    do ..Assert(##class(PI.REST).OriginAllowed("","127.0.0.1:52784",""),"nonbrowser callers still require the existing mutation header")
    write "ORIGIN_TESTS_OK",!
}
}
