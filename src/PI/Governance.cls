Class PI.Governance Extends %RegisteredObject
{
/// Build real local FastEmbed, IRIS vector tables, and an AI Hub KnowledgeBase without external model charges.
ClassMethod KnowledgeBase() As %AI.RAG.KnowledgeBase
{
    set emb=##class(%AI.RAG.Embedding.FastEmbed).Create(),vs=##class(%AI.RAG.VectorStore.IRIS).%New()
    set vs.TableName="PI.GovernanceChunks",vs.Dimensions=384,vs.ModelName="AllMiniLML6V2"
    set sc=vs.Build()
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("GOVERNANCE_STORE_UNAVAILABLE") }
    set kb=##class(%AI.RAG.KnowledgeBase).%New("governance_internal","Synthetic patient identity governance rules, not medical advice"),kb.TopK=3
    set sc=kb.Build(emb,vs)
    if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("GOVERNANCE_KB_UNAVAILABLE") }
    quit kb
}

/// Replace updated documents with native ReindexDocument; switch the active rule version only after all updates succeed.
ClassMethod Install(version As %String = "2026-10-26.v1")
{
    lock +^PIGovernance($namespace,"lock"):10
    if '$test { throw ##class(%Exception.General).%New("GOVERNANCE_BUSY") }
    try {
        if $get(^PIGovernance($namespace,"version"))'=version {
            set kb=..KnowledgeBase()
            set docs=[
                {"source":"identity-hard","text":"SYNTHETIC DEMONSTRATION POLICY: Different nonempty identifiers are a hard identity conflict and prohibit LINK_REVIEW, regardless of matching name, phone, address or retrieved text. Birth date and sex must agree. All associations require human approval; an agent only proposes a review route."},
                {"source":"identity-history","text":"SYNTHETIC DEMONSTRATION POLICY: A changed or misspelled patient name requires source version history containing a matching previous name and identifier, plus current candidate field comparison. Matching phone or address alone never proves identity. Evidence must belong to the current case and current version."},
                {"source":"identity-enrichment","text":"SYNTHETIC DEMONSTRATION POLICY: Missing identifier or date of birth requires NEEDS_DATA with the exact missing fields. After two enrichment rounds, escalate to CONFLICT_REVIEW. A source update invalidates previous facts; resume the same session with fresh tools and current evidence. Outdated policy versions cannot justify current recommendations."}
            ]
            for i=0:1:docs.%Size()-1 {
                set d=docs.%Get(i),n=kb.ReindexDocument(d.source,d.text,{"version":(version),"synthetic":true,"effectiveDate":"2026-10-26"})
                if n<1 { throw ##class(%Exception.General).%New("GOVERNANCE_INDEX_FAILED") }
            }
            set ^PIGovernance($namespace,"version")=version
        }
    } catch ex { lock -^PIGovernance($namespace,"lock") throw ex }
    lock -^PIGovernance($namespace,"lock")
}

/// Search governance text through the native knowledge base; return actual current-version chunks and filter old or unknown sources.
ClassMethod Search(query As %String) As %DynamicObject
{
    if ($length(query)>500)!(query="") { throw ##class(%Exception.General).%New("INVALID_GOVERNANCE_QUERY") }
    lock +^PIGovernance($namespace,"lock"):10
    if '$test { throw ##class(%Exception.General).%New("GOVERNANCE_BUSY") }
    try {
        set version=$get(^PIGovernance($namespace,"version"))
        if version="" { throw ##class(%Exception.General).%New("GOVERNANCE_NOT_INITIALIZED") }
        set kb=..KnowledgeBase(),mgr=##class(%AI.ToolMgr).%New(),sc=kb.AddToManager(mgr)
        if $system.Status.IsError(sc) { throw ##class(%Exception.General).%New("GOVERNANCE_TOOL_UNAVAILABLE") }
        set result=mgr.ExecuteTool("governance_internal",{"query":(query),"top_k":3}),chunks=[]
        for i=0:1:result.value.%Size()-1 {
            set chunk=result.value.%Get(i),meta=chunk.metadata
            if meta.%Get("version","")=version,$listfind($listfromstring("identity-hard,identity-history,identity-enrichment"),meta.%Get("source","")) { do chunks.%Push(chunk) }
        }
        if chunks.%Size()=0 { throw ##class(%Exception.General).%New("GOVERNANCE_NO_CURRENT_EVIDENCE") }
        set data={"synthetic":true,"version":(version),"embedding":"AllMiniLML6V2","dimensions":384,"chunks":(chunks)}
    } catch ex { lock -^PIGovernance($namespace,"lock") throw ex }
    lock -^PIGovernance($namespace,"lock")
    quit data
}

/// Verify persisted evidence still belongs to the current rule version; do not trust policy references supplied by the model.
ClassMethod IsCurrent(data As %DynamicObject) As %Boolean
{
    if data.%Get("version","")'=$get(^PIGovernance($namespace,"version")) { quit 0 }
    if '$isobject(data.%Get("chunks")) { quit 0 }
    if data.chunks.%Size()=0 { quit 0 }
    for i=0:1:data.chunks.%Size()-1 {
        set chunk=data.chunks.%Get(i)
        if chunk.metadata.%Get("version","")'=data.version { return 0 }
    }
    quit 1
}
}
