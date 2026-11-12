"""Python PEX operation for bounded, explanatory patient-name similarity."""
import difflib
import json
import unicodedata

from iris.pex import BusinessOperation


class NameSimilarityOperation(BusinessOperation):
    """Keep the original name-v1 score separate from authoritative identity decisions."""

    def OnMessage(self, request):
        """Validate the native request and return a native reply over the actual PEX gateway."""
        try:
            raw = request.get("Payload")
            if not isinstance(raw, str) or len(raw) > 12000:
                raise ValueError("INVALID_NAME_INPUT")
            data = json.loads(raw)
            if not isinstance(data, dict):
                raise ValueError("INVALID_NAME_INPUT")
            left, right = data.get("left"), data.get("right")
            if not isinstance(left, str) or not isinstance(right, str):
                raise ValueError("INVALID_NAME_INPUT")
            if len(left) > 500 or len(right) > 500:
                raise ValueError("FIELD_TOO_LONG")
            # Normalize copies only: this supporting score must never alter source records or hard conflicts.
            a = " ".join(unicodedata.normalize("NFKC", left).casefold().split())
            b = " ".join(unicodedata.normalize("NFKC", right).casefold().split())
            comparable = bool(a and b)
            score = difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() if comparable else 0
            result = {"comparable": comparable, "score": score, "algorithmVersion": "name-v1", "transport": "pex"}
        except (ValueError, TypeError) as error:
            code = "FIELD_TOO_LONG" if str(error) == "FIELD_TOO_LONG" else "INVALID_NAME_INPUT"
            result = {"code": code}
        except Exception:
            # Never expose gateway exceptions, source names or machine paths in application responses.
            result = {"code": "PEX_NAME_UNAVAILABLE"}
        response = request._iris.classMethodObject("PI.Reply", "%New")
        response.set("Payload", json.dumps(result, ensure_ascii=False, allow_nan=False))
        return response
