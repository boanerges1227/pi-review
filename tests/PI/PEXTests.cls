Class PI.PEXTests Extends PI.Tests
{
/// Exercise the actual Python PEX Production operation, including Unicode and bounded failure responses.
ClassMethod Run()
{
    if $namespace'="PITEST" { throw ##class(%Exception.General).%New("TEST_SCOPE") }
    do ##class(PI.PEX.Setup).Install()
    set sc=$system.OBJ.Compile("PI.Production","ck")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    if ##class(Ens.Director).IsProductionRunning() { set sc=##class(Ens.Director).UpdateProduction() }
    else { set sc=##class(Ens.Director).StartProduction("PI.Production") }
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    set result=##class(PI.PEX.Client).CompareNames("  ANNA   SMITH ","anna smith")
    do ..Assert(result.comparable&&(result.score=1),"PEX preserves case and whitespace normalization")
    do ..Assert(result.transport="pex"&&(result.algorithmVersion="name-v1"),"the response comes from the registered PEX operation")
    set result=##class(PI.PEX.Client).CompareNames($char(65313,65326,65326,65313),"anna")
    do ..Assert(result.score=1,"PEX normalizes Unicode compatibility characters")
    set result=##class(PI.PEX.Client).CompareNames("Anna","Ana")
    do ..Assert((result.score>0.85)&&(result.score<0.86),"PEX returns the original bounded name-v1 score")
    set result=##class(PI.PEX.Client).CompareNames("   ","Anna")
    do ..Assert('result.comparable&&(result.score=0),"missing names never become matching evidence")
    set denied=0
    try { set result=##class(PI.PEX.Client).CompareNames($justify("",501),"Anna") } catch ex { set denied=(ex.Name="FIELD_TOO_LONG") }
    do ..Assert(denied,"oversized names are rejected before dispatch")
    // Calling the operation directly must still validate input independently of the trusted client.
    set sc=##class(Ens.Director).CreateBusinessService("Intake",.service),request=##class(PI.Message).%New()
    set request.Payload={"left":5,"right":"Anna"}.%ToJSON(),sc=service.SendRequestSync("NameSimilarityPEX",request,.reply,10)
    do ..Assert($system.Status.IsOK(sc),"invalid PEX input returns a controlled response")
    set result={}.%FromJSON(reply.Payload)
    do ..Assert(result.code="INVALID_NAME_INPUT","the Python operation rejects non-string names")
    set request=##class(PI.Message).%New(),request.Payload="not json",sc=service.SendRequestSync("NameSimilarityPEX",request,.reply,10)
    do ..Assert($system.Status.IsOK(sc),"malformed JSON does not terminate the operation")
    set result={}.%FromJSON(reply.Payload)
    do ..Assert(result.code="INVALID_NAME_INPUT","malformed JSON has a safe response")
    set request=##class(PI.Message).%New(),request.Payload={"left":($justify("",501)),"right":"Anna"}.%ToJSON(),sc=service.SendRequestSync("NameSimilarityPEX",request,.reply,10)
    set result={}.%FromJSON(reply.Payload)
    do ..Assert(result.code="FIELD_TOO_LONG","the Python operation independently bounds input length")
    set oldCases=##class(PI.Store).List().%ToJSON()
    do ##class(PI.PEX.Setup).Install()
    do ..Assert(##class(PI.Store).List().%ToJSON()=oldCases,"repeated registration preserves business cases")
    set service="",sc=##class(Ens.Director).StopProduction(,1),denied=0
    try { set result=##class(PI.PEX.Client).CompareNames("Anna","Anna") } catch ex { set denied=(ex.Name="PEX_NAME_UNAVAILABLE") }
    set sc=##class(Ens.Director).StartProduction("PI.Production")
    if $system.Status.IsError(sc) { throw ##class(%Exception.StatusException).CreateFromStatus(sc) }
    do ..Assert(denied,"unavailable PEX cannot silently return a native comparison")
    write "PI_PEX_TESTS_OK",!
}
}
