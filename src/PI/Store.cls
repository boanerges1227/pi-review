Class PI.Store Extends %RegisteredObject
{
/// Read independent copies from persistent globals so callers cannot silently alter saved evidence.
ClassMethod Record(id As %String) As %DynamicObject
{
    if '$data(^PIData($namespace,"record",id)) { throw ##class(%Exception.General).%New("NOT_FOUND") }
    quit {}.%FromJSON(^PIData($namespace,"record",id))
}

/// Read a case and reject requests for nonexistent IDs.
ClassMethod Case(id As %String) As %DynamicObject
{
    if '$data(^PIData($namespace,"case",id)) { throw ##class(%Exception.General).%New("NOT_FOUND") }
    quit {}.%FromJSON(^PIData($namespace,"case",id))
}

/// Attach the timestamp and current IRIS process identity to every audit record.
ClassMethod Audit(caseId As %String, event As %String, detail As %String = "")
{
    set n=$increment(^PIData($namespace,"seq","audit"))
    set ^PIData($namespace,"audit",caseId,n)={"event":(event),"detail":(detail),"time":($zdatetime($horolog,3)),"actor":($username)}.%ToJSON()
}

/// Maintain versions, indexes, and cases in one transaction during ingestion to avoid partial writes.
ClassMethod Ingest(input As %DynamicObject) As %DynamicObject
{
    set r=##class(PI.Rules).Normalize(input),canonical=r.%ToJSON()
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        tstart
        set rid=$get(^PIData($namespace,"source",r.sourceSystem,r.sourcePatientId)),old={}
        if rid'="" {
            set old=..Record(rid)
            if $data(^PIData($namespace,"version",rid,r.sourceVersion)) {
                if ^PIData($namespace,"version",rid,r.sourceVersion)'=canonical { throw ##class(%Exception.General).%New("VERSION_CONFLICT") }
                set answer={"recordId":(rid),"caseId":($get(^PIData($namespace,"recordCase",rid))),"masterId":(old.masterId),"status":"ACCEPTED","duplicate":true}
                tcommit
                lock -^PIData($namespace,"lock")
                return answer
            }
            if r.sourceVersion<old.sourceVersion { throw ##class(%Exception.General).%New("STALE_SOURCE_VERSION") }
            set keys=##class(PI.Rules).Keys(old)
            for i=0:1:keys.%Size()-1 { kill ^PIData($namespace,"index",keys.%Get(i),rid) }
        } else {
            set rid=$increment(^PIData($namespace,"seq","record"))
        }
        set r.id="r"_rid,r.masterId=old.%Get("masterId","")
        set result=##class(PI.Rules).Candidates(r,rid),cid=$get(^PIData($namespace,"recordCase",rid))
        if (result.items.%Size()=0)&&(r.birthDate'="")&&(r.identifier'="")&&(cid="") {
            if r.masterId="" { set r.masterId="m"_$increment(^PIData($namespace,"seq","master")) }
            set status="ACCEPTED"
        } else {
            if cid="" { set cid="c"_$increment(^PIData($namespace,"seq","case")),version=1,rounds=0 } else {
                set previous=..Case(cid),version=previous.version+1,rounds=previous.rounds
                if previous.status="NEEDS_DATA" { set rounds=rounds+1 }
            }
            set status="PENDING_AGENT"
            if result.truncated { set status="CONFLICT_REVIEW" }
            if rounds>=2 { set status="CONFLICT_REVIEW" }
            set c={"id":(cid),"version":(version),"incomingId":(rid),"incoming":(r),"candidates":(result.items),"truncated":(result.truncated),"status":(status),"rounds":(rounds),"correlationId":("pi-"_cid),"ruleVersion":"1","mode":"not-run"}
            set ^PIData($namespace,"case",cid)=c.%ToJSON(),^PIData($namespace,"recordCase",rid)=cid,^PIData($namespace,"caseRefs",rid,cid)=1
            for i=0:1:result.items.%Size()-1 {
                set candidate=result.items.%Get(i)
                set ^PIData($namespace,"caseRefs",$extract(candidate.id,2,*),cid)=1
            }
            do ..Audit(cid,"INTAKE",status)
        }
        // Bump other cases that reference this source to prevent reviews based on stale snapshots.
        set ref=""
        for {
            set ref=$order(^PIData($namespace,"caseRefs",rid,ref)) quit:ref=""
            continue:ref=cid
            set affected=..Case(ref)
            if affected.status'="APPROVED" {
                set affected.version=affected.version+1,affected.status="CONFLICT_REVIEW",affected.stale=1
                set ^PIData($namespace,"case",ref)=affected.%ToJSON()
            }
        }
        set ^PIData($namespace,"record",rid)=r.%ToJSON(),^PIData($namespace,"source",r.sourceSystem,r.sourcePatientId)=rid
        set ^PIData($namespace,"version",rid,r.sourceVersion)=canonical
        set keys=##class(PI.Rules).Keys(r)
        for i=0:1:keys.%Size()-1 { set ^PIData($namespace,"index",keys.%Get(i),rid)=1 }
        set answer={"recordId":(rid),"caseId":(cid),"masterId":(r.masterId),"status":(status),"duplicate":false}
        tcommit
    } catch ex {
        if $tlevel { trollback }
        lock -^PIData($namespace,"lock")
        throw ex
    }
    lock -^PIData($namespace,"lock")
    quit answer
}

/// List only current case summaries and limit each response size.
ClassMethod List() As %DynamicArray
{
    set a=[],id=""
    for { set id=$order(^PIData($namespace,"case",id)) quit:id=""  do a.%Push(..Case(id)) quit:a.%Size()>=100 }
    quit a
}

/// Collect current-version evidence, model calls, and audits for the review display.
ClassMethod Detail(id As %String) As %DynamicObject
{
    set c=..Case(id),e=[],a=[],t=[],key=""
    set c.baseline=##class(PI.Rules).Baseline(c.incoming,c.candidates)
    set evidenceVersion=$get(^PIData($namespace,"evidenceVersion",id),c.%Get("evidenceVersion",c.version))
    for { set key=$order(^PIData($namespace,"evidence",id,evidenceVersion,key)) quit:key=""  do e.%Push({}.%FromJSON(^PIData($namespace,"evidence",id,evidenceVersion,key))) }
    set key=""
    for { set key=$order(^PIData($namespace,"audit",id,key)) quit:key=""  do a.%Push({}.%FromJSON(^PIData($namespace,"audit",id,key))) }
    set key=""
    for { set key=$order(^PIData($namespace,"run",id,key)) quit:key=""  do t.%Push({}.%FromJSON(^PIData($namespace,"run",id,key))) }
    set c.evidence=e,c.audit=a,c.runs=t,c.toolTrace=##class(PI.ToolAudit).List(id),mcp=[],key=""
    for { set key=$order(^PIData($namespace,"mcpTrace",id,key)) quit:key=""  do mcp.%Push({}.%FromJSON(^PIData($namespace,"mcpTrace",id,key))) quit:mcp.%Size()>=100 }
    set c.mcpTrace=mcp
    if c.%Get("enrichmentVersion",0)>0,$data(^PIData($namespace,"enrichment",id,c.enrichmentVersion)) { set c.enrichment={}.%FromJSON(^PIData($namespace,"enrichment",id,c.enrichmentVersion)) }
    quit c
}

/// Recall candidates and create a new snapshot after source changes; retain old conclusions only in the audit.
ClassMethod Refresh(id As %String) As %DynamicObject
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set c=..Case(id)
        if c.%Get("stale",0) {
            set r=..Record(c.incomingId),found=##class(PI.Rules).Candidates(r,c.incomingId)
            set c.incoming=r,c.candidates=found.items,c.truncated=found.truncated,c.stale=0,c.version=c.version+1
            set c.status=$select(found.truncated:"CONFLICT_REVIEW",1:"PENDING_AGENT"),c.mode="not-run"
            do c.%Remove("result")
            set ^PIData($namespace,"case",id)=c.%ToJSON()
            for i=0:1:found.items.%Size()-1 {
                set item=found.items.%Get(i),^PIData($namespace,"caseRefs",$extract(item.id,2,*),id)=1
            }
            do ..Audit(id,"REFRESH_SNAPSHOT")
        }
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
    quit c
}
}
