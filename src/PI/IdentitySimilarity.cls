Class PI.IdentitySimilarity Extends %RegisteredObject
{
/// Explain name differences inside the IRIS process; this score never authorizes an identity association.
ClassMethod CompareNames(left As %String, right As %String) As %DynamicObject [ Language = python ]
{
    import difflib
    import json
    import unicodedata
    import iris

    if len(left) > 500 or len(right) > 500:
        raise ValueError("FIELD_TOO_LONG")
    # Normalize copies only; exact identifiers, persisted names and candidate indexes remain unchanged.
    a = " ".join(unicodedata.normalize("NFKC", left).casefold().split())
    b = " ".join(unicodedata.normalize("NFKC", right).casefold().split())
    comparable = bool(a and b)
    score = difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if comparable else 0
    return iris.cls("%DynamicObject")._FromJSON(json.dumps({
        "comparable": comparable, "score": score, "algorithmVersion": "name-v1"
    }))
}
}
