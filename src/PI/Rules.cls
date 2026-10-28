Class PI.Rules Extends %RegisteredObject
{
/// Restrict input fields and lengths; treat patient fields as data rather than commands.
ClassMethod Normalize(input As %DynamicObject) As %DynamicObject
{
    if '$isobject(input) { throw ##class(%Exception.General).%New("INVALID_INPUT") }
    set r={}
    for i=1:1:9 {
        set k=$piece("sourceSystem,sourcePatientId,sourceVersion,name,birthDate,sex,identifier,phone,notes",",",i)
        if input.%IsDefined(k),input.%GetTypeOf(k)'="string",k'="sourceVersion" { throw ##class(%Exception.General).%New("INVALID_FIELD_TYPE") }
        do r.%Set(k,$zstrip(input.%Get(k,""),"<>W"))
        if $length(r.%Get(k))>500 { throw ##class(%Exception.General).%New("FIELD_TOO_LONG") }
    }
    if (r.sourceSystem="")!(r.sourcePatientId="")!($length(r.sourcePatientId)>100) { throw ##class(%Exception.General).%New("INVALID_SOURCE") }
    if r.sourceVersion'?1.N { throw ##class(%Exception.General).%New("INVALID_VERSION") }
    if (r.sourceVersion<1)!(r.sourceVersion>999999999) { throw ##class(%Exception.General).%New("INVALID_VERSION") }
    set r.sourceVersion=+r.sourceVersion
    if (r.name="")!(r.sex="") { throw ##class(%Exception.General).%New("MISSING_REQUIRED_FIELDS") }
    if r.birthDate'="" {
        set valid=0
        try { set d=$zdateh(r.birthDate,3),valid=($zdate(d,3)=r.birthDate) } catch ex { set valid=0 }
        if 'valid { throw ##class(%Exception.General).%New("INVALID_BIRTH_DATE") }
    }
    quit r
}

/// Normalize names only for indexing; preserve the original display value.
ClassMethod NameKey(name As %String) As %String
{
    quit $zconvert($translate(name," ",""),"U")
}

/// Use separate identifier and name/birth-date indexes to retain identifier matches with conflicting names.
ClassMethod Keys(r As %DynamicObject) As %DynamicArray
{
    set a=[]
    if r.identifier'="" { do a.%Push("ID:"_r.identifier) }
    if (r.name'="")&&(r.birthDate'="") { do a.%Push("NB:"_..NameKey(r.name)_":"_r.birthDate) }
    quit a
}

/// Traverse only matching index entries and explicitly truncate results above ten candidates.
ClassMethod Candidates(r As %DynamicObject, exclude As %String = "") As %DynamicObject
{
    set keys=..Keys(r),items=[],truncated=0
    for i=0:1:keys.%Size()-1 {
        set key=keys.%Get(i),rid=""
        for {
            set rid=$order(^PIData($namespace,"index",key,rid)) quit:rid=""
            continue:rid=exclude
            continue:$data(seen(rid))
            set seen(rid)=1
            if items.%Size()=10 { set truncated=1 quit }
            do items.%Push(##class(PI.Store).Record(rid))
        }
    }
    quit {"items":(items),"truncated":(truncated)}
}

/// Treat fixed-field comparisons as factual evidence; use an explicit SYN prefix for synthetic identifiers.
ClassMethod Compare(a As %DynamicObject, b As %DynamicObject) As %DynamicObject
{
    set differences=[],matches=[]
    for i=1:1:6 {
        set k=$piece("name,birthDate,sex,identifier,phone,notes",",",i),av=a.%Get(k,""),bv=b.%Get(k,"")
        if (av'="")&&(bv'="") {
            if av=bv { do matches.%Push(k) } else { do differences.%Push(k) }
        }
    }
    set strong=(a.identifier'="")&&(b.identifier'="")&&(a.identifier'=b.identifier)
    quit {"matches":(matches),"differences":(differences),"identifierConflict":(strong),"synthetic":true}
}

/// Keep the fixed-rule baseline independent of history to show the actual routing differences from Agent investigations.
ClassMethod Baseline(r As %DynamicObject, candidates As %DynamicArray) As %DynamicObject
{
    if (r.identifier="")!(r.birthDate="") { quit {"decision":"NEEDS_DATA","reason":"Required identity evidence is missing."} }
    if candidates.%Size()=0 { quit {"decision":"NEW","reason":"No indexed candidate."} }
    if candidates.%Size()=1 {
        set target=candidates.%Get(0)
        if (r.identifier=target.identifier)&&(..NameKey(r.name)=..NameKey(target.name))&&(r.birthDate=target.birthDate)&&(r.sex=target.sex) {
            quit {"decision":"LINK_REVIEW","reason":"All deterministic identity fields agree."}
        }
    }
    quit {"decision":"CONFLICT_REVIEW","reason":"Static rules cannot resolve the conflicting identity fields."}
}
}
