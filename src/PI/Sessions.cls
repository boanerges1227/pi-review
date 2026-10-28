Class PI.Sessions Extends %RegisteredObject
{
/// Restore SDK sessions only for the server-selected case; clear old facts and gather new evidence when versions or rules change.
ClassMethod Open(agent As %AI.Agent, c As %DynamicObject, Output resumed As %Boolean, Output reset As %Boolean) As %AI.Agent.Session
{
    set resumed=0,reset=0,id=$get(^PIData($namespace,"session",c.id,"id"))
    set promptHash=$system.Encryption.Base64Encode($system.Encryption.SHAHash(256,agent.SystemPrompt))
    set binding=promptHash_"|"_c.version_"|prompt-v2|"_$get(^PIGovernance($namespace,"version"),"unavailable")_"|"_##class(PI.ModelConfig).Name()_"|"_##class(PI.ModelConfig).Revision()_"|"_agent.Model
    if id'="" {
        set session=##class(%AI.Agent.Session).%OpenId(id,,.sc)
        if $system.Status.IsError(sc)!('$isobject(session)) { throw ##class(%Exception.General).%New("SESSION_RESTORE_FAILED") }
        // Reattachment reads the model from Session itself; synchronize the actual execution model before attaching.
        set session.Model=agent.Model,session.SystemPrompt=agent.SystemPrompt
        set sc=agent.ResumeSession(session,{"max_iterations":8,"max_tokens":1500})
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SESSION_RESTORE_FAILED") }
        set resumed=1
        if binding'=$get(^PIData($namespace,"session",c.id,"binding")) {
            set sc=session.ResetContext()
            if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SESSION_RESET_FAILED") }
            set reset=1
        }
        // Native stream import may restore an old base_system_prompt; update the actual Rust session again after attachment.
        set session.SystemPrompt=agent.SystemPrompt
    } else {
        set session=agent.CreateSession({"max_iterations":8,"max_tokens":1500})
    }
    set ^PIData($namespace,"context",$job,"sessionBinding")=binding
    quit session
}

/// Recheck versions under the same business lock before saving; never overwrite completed human review or source updates.
ClassMethod Save(c As %DynamicObject, session As %AI.Agent.Session, stage As %String = "complete")
{
    lock +^PIData($namespace,"lock"):3
    if '$test { throw ##class(%Exception.General).%New("BUSY") }
    try {
        set current=##class(PI.Store).Case(c.id)
        if (current.version'=c.version)!current.%Get("stale",0) { throw ##class(%Exception.General).%New("STALE_CASE") }
        set sc=session.%Save()
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("SESSION_SAVE_FAILED") }
        set ^PIData($namespace,"session",c.id,"id")=session.%Id()
        set ^PIData($namespace,"session",c.id,"checkpointStage")=stage,^PIData($namespace,"session",c.id,"checkpointRunId")=$get(^PIData($namespace,"context",$job,"runId"))
        set ^PIData($namespace,"session",c.id,"binding")=$get(^PIData($namespace,"context",$job,"sessionBinding"))
    } catch ex { lock -^PIData($namespace,"lock") throw ex }
    lock -^PIData($namespace,"lock")
}

/// The SDK stores cumulative usage; settle only this round's delta to avoid charging historical usage again.
ClassMethod Delta(before As %DynamicObject, after As %DynamicObject) As %DynamicObject
{
    set delta={}
    for key="total_prompt_tokens","total_completion_tokens","total_tokens","total_interactions","total_tool_calls","total_llm_duration_ms","total_tool_duration_ms","total_reasoning_tokens","total_cache_read_tokens","total_cache_creation_tokens" {
        if after.%IsDefined(key) {
            set value=after.%Get(key)-before.%Get(key,0)
            if value<0 { throw ##class(%Exception.General).%New("SESSION_STATS_REGRESSION") }
            do delta.%Set(key,value)
        }
    }
    quit delta
}
}
