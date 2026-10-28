Class PI.FHIR.REST Extends %CSP.REST
{
Parameter CHARSET = "utf-8";
Parameter HandleCorsRequest = 0;
XData UrlMap
{
<Routes>
  <Route Url="/:operation" Method="POST" Call="ProcessMessage"/>
</Routes>
}

/// Accept a synchronous FHIR Bundle through the same Production service and local mutation boundary.
ClassMethod ProcessMessage(operation As %String) As %Status
{
    try {
        if operation'="$process-message" { throw ##class(%Exception.General).%New("FHIR_OPERATION_NOT_FOUND") }
        if %request.GetCgiEnv("QUERY_STRING")'="" { throw ##class(%Exception.General).%New("FHIR_ASYNC_UNSUPPORTED") }
        set contentType=$zconvert($zstrip($piece(%request.GetCgiEnv("CONTENT_TYPE"),";"),"<>W"),"L")
        if contentType'="application/fhir+json" { throw ##class(%Exception.General).%New("FHIR_CONTENT_TYPE_REQUIRED") }
        set body=##class(PI.REST).Body()
        if body.%Get("resourceType","")'="Bundle" { throw ##class(%Exception.General).%New("FHIR_BUNDLE_REQUIRED") }
        set result=##class(PI.REST).Submit(body)
        if result.%Get("resourceType","")'="Bundle" { throw ##class(%Exception.General).%New("FHIR_BUNDLE_REQUIRED") }
    } catch ex { return ..RespondOutcome(ex.Name) }
    quit ..Json(result)
}

/// Return a controlled R4 OperationOutcome for transport or profile failures.
ClassMethod RespondOutcome(code As %String) As %Status
{
    set status=400
    if code="FHIR_OPERATION_NOT_FOUND" { set status=404 }
    if code="FORBIDDEN" { set status=403 }
    if (code="FHIR_MESSAGE_ID_CONFLICT")!(code="VERSION_CONFLICT")!(code="STALE_SOURCE_VERSION")!(code="STALE_CASE")!(code="CASE_CLOSED") { set status=409 }
    if code="INPUT_TOO_LARGE" { set status=413 }
    if code="FHIR_CONTENT_TYPE_REQUIRED" { set status=415 }
    if (code="BUSY")!(code="PRODUCTION_UNAVAILABLE") { set status=503 }
    if $extract(code,1)="<" { set status=500,code="FHIR_INTERNAL_ERROR" }
    set %response.Status=status_" "_$select(status=400:"Bad Request",status=403:"Forbidden",status=404:"Not Found",status=409:"Conflict",status=413:"Payload Too Large",status=415:"Unsupported Media Type",status=503:"Service Unavailable",1:"Internal Server Error")
    quit ..Json({"resourceType":"OperationOutcome","issue":[{"severity":"error","code":($select(status=409:"conflict",status=403:"forbidden",status=503:"transient",status=500:"exception",1:"invalid")),"details":{"text":(code)}}]})
}

/// Emit FHIR JSON with no caching and no stack traces or raw request content.
ClassMethod Json(data As %DynamicObject) As %Status
{
    set %response.ContentType="application/fhir+json; charset=utf-8"
    do %response.SetHeader("Cache-Control","no-store")
    do %response.SetHeader("X-Content-Type-Options","nosniff")
    write data.%ToJSON()
    quit 1
}
}
