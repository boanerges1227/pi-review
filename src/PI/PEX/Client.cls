Class PI.PEX.Client Extends %RegisteredObject
{
/// Collect supporting similarity through the real Production operation; never substitute a native result after PEX failure.
ClassMethod CompareNames(left As %String, right As %String) As %DynamicObject
{
    if ($length(left)>500)!($length(right)>500) { throw ##class(%Exception.General).%New("FIELD_TOO_LONG") }
    try {
        set sc=##class(Ens.Director).CreateBusinessService("Intake",.service)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
        set request=##class(PI.Message).%New(),request.Payload={"left":(left),"right":(right)}.%ToJSON()
        set sc=service.SendRequestSync("NameSimilarityPEX",request,.response,10)
        if $system.Status.IsError(sc)!('$isobject(response)) { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
        set result={}.%FromJSON(response.Payload)
        if result.%IsDefined("code") { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
        if (result.%Get("transport","")'="pex")!(result.%Get("algorithmVersion","")'="name-v1") { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
        if (result.%GetTypeOf("score")'="number")!(result.%GetTypeOf("comparable")'="boolean") { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
        if (result.score<0)!(result.score>1) { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
    } catch ex { throw ##class(%Exception.General).%New("PEX_NAME_UNAVAILABLE") }
    quit result
}
}
