# Identity result callback: Custom Outbound Adapter

Human LINK, SEPARATE, REJECT and UNDO decisions create immutable callback events in the same IRIS transaction as the case/mapping change. Sending happens afterward through `IdentityResultRelay` → `IdentityResultOutbound` → `PI.Adapter.IdentityResultOutbound`. The custom adapter extends `EnsLib.HTTP.OutboundAdapter`; it implements the identity-result wire protocol, fixed idempotency header and strict receipt validation.

Review entry points own their commit boundary and reject an already active caller transaction (`REVIEW_TRANSACTION_UNSUPPORTED`). The relay briefly shares the review lock when claiming work, preventing raw-global visibility from exposing an uncommitted event. All network I/O happens after that lock is released.

The included HIS is a synthetic test receiver. Native Production and HTTP delivery are exercised, but no real hospital endpoint, credentials or acceptance is implied.

## Enable in a configured installation

Both new items in `PI.Production` are **disabled by default**, with no destination server. Install/reload the updated classes and update the Production configuration during your normal maintenance window. Check the existing Production settings before applying a replacement definition.

1. In the native Production portal, configure `IdentityResultOutbound` adapter settings: `HTTPServer`, `HTTPPort`, `URL` (default `/identity-results`), and the named IRIS `Credentials` entry if authentication is required. Set `SSLConfig` for HTTPS and keep server identity checking enabled. The destination must implement the receipt contract below.
2. Keep `ConnectTimeout`, `ResponseTimeout` and `WriteTimeout` positive, with a total at most 45 seconds (defaults 5, 10 and 5). The 60-second queue lease must outlive network I/O. Redirects are not followed.
3. Configure operation settings `MaxAttempts` (default 3, range 1–20) and `RetrySeconds` (default 5, range 1–3600). Configure relay adapter `CallInterval` (default 5 seconds).
4. Enable `IdentityResultOutbound`, then `IdentityResultRelay`, and apply the Production changes. To pause delivery, disable the relay first; already queued/in-flight work may still complete. Disabling the operation suspends its native queue; no committed review is undone.

Pending events created while delivery was disabled are sent after enabling. Historical `simulated=true` notifications are retained and never automatically replayed. A real HIS may require its own protocol/authentication mapping; this contract is deliberately explicit rather than claiming universal HIS compatibility.

## Request and receipt

`POST /identity-results`, `Content-Type: application/json`, and `Idempotency-Key` equal to `eventId`:

```json
{
  "schemaVersion": 1,
  "eventId": "pi-<globally-unique-id>",
  "caseId": "c1",
  "caseVersion": 2,
  "sourceSystem": "HIS",
  "sourcePatientId": "synthetic-p1",
  "sourceVersion": 1,
  "kind": "APPROVAL",
  "action": "LINK",
  "previousMasterId": "",
  "masterId": "m1",
  "occurredAt": "2026-11-13T00:00:00Z"
}
```

`action` is `LINK`, `SEPARATE`, `REJECT`, or `UNDO`; UNDO uses `kind=CORRECTION`, other actions use `APPROVAL`. REJECT reports the unchanged mapping, including an empty mapping when applicable. UNDO reports the restored mapping. Source identifiers identify the record being reviewed; `caseVersion` is the post-decision version. Names, dates of birth, identity-document numbers, model evidence and reviewer free text are not sent.

Success requires HTTP **200 or 201** and a JSON object at most 8192 bytes:

```json
{"eventId":"pi-<same-id>","status":"ACCEPTED","receiptId":"his-<stable-receipt>"}
```

An already applied identical event returns `status=DUPLICATE` and the original receipt ID. The receiver must durably deduplicate by `eventId` and reject the same ID with different content. Transport status alone is insufficient: a mismatched event ID, missing receipt ID, malformed body, or another status cannot mark the notification SENT. Only the three receipt fields are persisted.

## Retry, ordering and recovery

- `PENDING` → `QUEUED` → `SENT`; failures become `RETRY`, then `FAILED` after `MaxAttempts` in a retry cycle. All delivery failures use the same bounded retry policy. `attempts` counts lifetime attempts; explicit recovery resets only the cycle count.
- A durable outbox prevents losing an event between review commit and queue submission. The relay scans at most 100 pending entries per tick with a rotating cursor. An abandoned queue lease becomes eligible again after 60 seconds; the next poll requeues it after a restart. Duplicate queue entries skip already sent events.
- Each source-system/patient pair has an event predecessor. A later event, including an undo, waits until its predecessor is SENT. An exhausted predecessor deliberately blocks later events until recovered; inspect and repair the earlier failure first.
- Sending holds only an event-specific lock. HTTP errors and HIS downtime do not roll back human decisions. If HIS committed but its receipt was lost, the same ID/payload is resent; HIS must deduplicate. This is **at-least-once delivery with receiver deduplication**, not a distributed exactly-once transaction.
- Inspect notification rows in `^PIData($namespace,"notification",id)` and `NOTIFICATION_*` case audit events. `lastError=HIS_DELIVERY_FAILED` is a controlled error code; remote response bodies are not copied into the audit. The native Production trace contains the notification request ID.
- After correcting an endpoint or receiver error, explicitly reopen an exhausted event in the application's namespace:

```objectscript
do ##class(PI.Route).Notify("n1")
```

Run recovery outside an existing transaction. Reopening the row, restoring its pending index and recording its audit entry is atomic. This preserves the original ID, payload and lifetime attempts. It does not resend SENT events or historical simulated rows. If a worker was interrupted after its final attempt was recorded, recovery marks the event FAILED (`HIS_ATTEMPTS_EXHAUSTED`) without exceeding the limit; an operator can explicitly reopen that ambiguous attempt with the same event ID. No public retry HTTP endpoint is added.

## Reproducible validation

```bash
bash scripts/notification-smoke.sh
```

The script uses the locally available AI Hub image (override `IRIS_IMAGE` when needed). It creates a fresh `--network none` container, mounts the checkout read-only, starts the HIS on container loopback port 18894, compiles project classes, runs real native Production tests, and deletes the container afterward. No published ports, business volumes or model credentials are used. Logs are kept in ignored `artifacts/notification-smoke/`.

The receiver at `tests/mock_his.py` uses SQLite transactions for persistent, concurrent deduplication. `/__test/control` and `/__test/state` are test-only endpoints. Never expose the mock receiver publicly or use it as a production HIS.

Coverage includes matching receipts, LINK/SEPARATE/REJECT/UNDO payloads, HTTP failure/retry, exhausted attempts/manual recovery, lost/wrong/missing/malformed receipts, concurrent duplicates, receiver restart, outbox transaction rollback and Production restart/expired-lease recovery.
