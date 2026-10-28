"""Verify synchronous R4 messaging through the actual local Production with synthetic data."""
import json
import os
import uuid
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BASE = os.environ.get("PI_BASE", "http://127.0.0.1:52784")


def patient_message(bundle_id, header_id, patient_id, source, version=1):
    """Create literal message and resource references without real patient information."""
    header_url = "urn:uuid:" + str(uuid.uuid4())
    patient_url = "urn:uuid:" + str(uuid.uuid4())
    return {"resourceType": "Bundle", "id": bundle_id, "type": "message", "entry": [
        {"fullUrl": header_url, "resource": {"resourceType": "MessageHeader", "id": header_id,
            "eventCoding": {"system": "https://example.org/fhir/CodeSystem/identity-event", "code": "patient-upsert"},
            "source": {"endpoint": "urn:pi:source:" + source}, "focus": [{"reference": patient_url}]}},
        {"fullUrl": patient_url, "resource": {"resourceType": "Patient", "id": patient_id,
            "meta": {"versionId": str(version)}, "identifier": [{"system": "https://example.org/fhir/identifier/synthetic-person", "value": "SYN-FHIR-" + patient_id}],
            "name": [{"text": "FHIR Synthetic " + patient_id}], "gender": "female", "birthDate": "1988-03-17",
            "telecom": [{"system": "phone", "value": "TEST-PHONE-FHIR"}]}}
    ]}


def request(path, body, headers=None):
    """Keep error status and content type visible for boundary assertions."""
    headers = headers if headers is not None else {"Content-Type": "application/fhir+json", "X-Identity-Review": "local-demo"}
    req = Request(BASE + path, json.dumps(body).encode(), headers)
    try:
        response = urlopen(req, timeout=30)
    except HTTPError as exc:
        response = exc
    with response:
        raw = response.read()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"code": "NON_FHIR_RESPONSE"}
        return response.status, response.headers, body


def parameters(bundle):
    """Read the structured Parameters resource referenced by the response header."""
    resource = next(x["resource"] for x in bundle["entry"] if x["resource"]["resourceType"] == "Parameters")
    return {p["name"]: p.get("valueString", p.get("valueBoolean")) for p in resource["parameter"]}


class FHIRAcceptance(unittest.TestCase):
    """Exercise real accepted and rejected messages without model calls or external hospital data."""

    def test_fhir_route_cannot_invoke_other_production_actions(self):
        """A FHIR endpoint must never interpret supplied workflow action fields as an AI request."""
        status, _, result = request("/identity-fhir/$process-message", {"action": "investigate", "caseId": "c999999"})
        self.assertEqual(status, 400)
        self.assertIn("FHIR_BUNDLE_REQUIRED", json.dumps(result))
        body = patient_message("bundle-injection", "header-injection", "FHIR-injection", "HIS")
        body["action"] = "investigate"
        body["caseId"] = "c999999"
        status, _, result = request("/identity-fhir/$process-message", body)
        self.assertEqual(status, 400)
        self.assertIn("FHIR_INVALID_STRUCTURE", json.dumps(result))

    def test_sync_production_retry_and_fhir_errors(self):
        """A synthetic message reaches Production exactly once and returns the original FHIR reply on retry."""
        suffix = uuid.uuid4().hex[:12]
        bundle = patient_message("bundle-" + suffix, "header-" + suffix, "FHIR-" + suffix, "HIS")
        status, headers, result = request("/identity-fhir/$process-message", bundle)
        self.assertEqual(status, 200, result)
        self.assertTrue(headers.get("Content-Type", "").startswith("application/fhir+json"))
        self.assertEqual(result["resourceType"], "Bundle")
        self.assertEqual(result["type"], "message")
        self.assertEqual(result["entry"][0]["resource"]["resourceType"], "MessageHeader")
        self.assertEqual(result["entry"][0]["resource"]["response"]["identifier"], bundle["entry"][0]["resource"]["id"])
        self.assertEqual(parameters(result)["status"], "ACCEPTED")
        self.assertFalse(parameters(result)["duplicate"])
        status, _, retry = request("/identity-fhir/$process-message", bundle)
        self.assertEqual(status, 200)
        self.assertEqual(retry, result)
        altered = json.loads(json.dumps(bundle))
        altered["entry"][1]["resource"]["name"][0]["text"] = "Changed Synthetic Name"
        status, headers, error = request("/identity-fhir/$process-message", altered)
        self.assertEqual(status, 409)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        self.assertTrue(headers.get("Content-Type", "").startswith("application/fhir+json"))
        self.assertIn("FHIR_MESSAGE_ID_CONFLICT", json.dumps(error))
        wrong = json.loads(json.dumps(bundle))
        wrong["id"] = "bad-" + suffix
        wrong["entry"][0]["resource"]["id"] = "bad-header-" + suffix
        wrong["entry"][1]["resource"]["meta"]["versionId"] = "opaque-v2"
        status, _, error = request("/identity-fhir/$process-message", wrong)
        self.assertEqual(status, 400)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        self.assertIn("FHIR_VERSION_UNSUPPORTED", json.dumps(error))
        status, _, error = request("/identity-fhir/$process-message?async=true", bundle)
        self.assertEqual(status, 400)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        status, _, error = request("/identity-fhir/$process-message", bundle, {"Content-Type": "application/fhir+json"})
        self.assertEqual(status, 403)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        status, _, error = request("/identity-fhir/$process-message", bundle, {"Content-Type": "application/json", "X-Identity-Review": "local-demo"})
        self.assertEqual(status, 415)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        status, _, error = request("/identity-fhir/$process-message", bundle, {"Content-Type": "application/fhir+json", "X-Identity-Review": "local-demo", "Origin": "https://invalid.example"})
        self.assertEqual(status, 403)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        status, _, error = request("/identity-fhir/invalid-operation", bundle)
        self.assertEqual(status, 404)
        self.assertEqual(error["resourceType"], "OperationOutcome")
        second = patient_message("second-" + suffix, "second-header-" + suffix, "FHIR-SECOND-" + suffix, "EMR")
        second["entry"][1]["resource"]["identifier"] = bundle["entry"][1]["resource"]["identifier"]
        second["entry"][1]["resource"]["name"] = bundle["entry"][1]["resource"]["name"]
        status, _, review = request("/identity-fhir/$process-message", second)
        self.assertEqual(status, 200, review)
        review_params = parameters(review)
        self.assertEqual(review_params["status"], "PENDING_AGENT")
        self.assertTrue(review_params["caseId"])
        update = json.loads(json.dumps(second))
        update["id"] = "update-" + suffix
        update["entry"][0]["resource"]["id"] = "update-header-" + suffix
        update["entry"][1]["resource"]["meta"]["versionId"] = "2"
        status, _, updated = request("/identity-fhir/$process-message", update)
        self.assertEqual(status, 200, updated)
        self.assertEqual(parameters(updated)["caseId"], review_params["caseId"])
        print("FHIR synthetic records:", parameters(result)["recordId"], review_params["recordId"], "case:", review_params["caseId"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
