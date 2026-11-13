"""Loopback-only synthetic HIS; its control endpoints are exclusively for tests."""
import argparse
import json
import socket
import sqlite3
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def make_server(host, port, database):
    """Create a receiver whose receipts and deduplication survive process restarts."""
    if host != '127.0.0.1':
        raise ValueError('The synthetic receiver must bind to loopback')
    with sqlite3.connect(database) as db:
        db.executescript('''
            CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, payload TEXT, receipt TEXT);
            CREATE TABLE IF NOT EXISTS attempts (id TEXT PRIMARY KEY, count INTEGER);
            CREATE TABLE IF NOT EXISTS controls (patient TEXT PRIMARY KEY, mode TEXT);
            CREATE TABLE IF NOT EXISTS mappings (
                source TEXT, patient TEXT, case_id TEXT, version INTEGER, master TEXT,
                PRIMARY KEY (source, patient));
        ''')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            """Do not print synthetic patient identifiers or callback bodies."""

        def reply(self, status, data):
            """Send a complete JSON response with a bounded connection lifetime."""
            body = json.dumps(data).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            """Expose inspectable synthetic effects without exposing the receiver publicly."""
            if self.path != '/__test/state':
                return self.reply(404, {'error': 'NOT_FOUND'})
            with sqlite3.connect(database) as db:
                data = {'accepted': db.execute('SELECT COUNT(*) FROM events').fetchone()[0],
                        'attempts': db.execute('SELECT COALESCE(SUM(count),0) FROM attempts').fetchone()[0],
                        'events': [json.loads(r[0]) for r in db.execute('SELECT payload FROM events ORDER BY rowid')],
                        'mappings': [{'sourceSystem': r[0], 'sourcePatientId': r[1], 'masterId': r[2]}
                                     for r in db.execute('SELECT source,patient,master FROM mappings ORDER BY source,patient')]}
            self.reply(200, data)

        def do_POST(self):
            """Validate the contract, then atomically apply or deduplicate a result."""
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 32768:
                    return self.reply(413, {'error': 'BODY_SIZE'})
                event = json.loads(self.rfile.read(size))
                if not isinstance(event, dict):
                    raise ValueError('OBJECT_REQUIRED')
                if self.path == '/__test/control':
                    mode = event['mode']
                    if mode not in ('normal', 'fail-once', 'drop-once', 'wrong-ack-once',
                                    'always-fail', 'malformed-once', 'missing-receipt-once',
                                    'invalid-status-once', 'http-error-once', 'oversized-once',
                                    'wrong-id-type-once', 'long-receipt-once', 'empty-receipt-once', 'slow-once'):
                        raise ValueError('UNKNOWN_MODE')
                    with sqlite3.connect(database) as db:
                        db.execute('INSERT OR REPLACE INTO controls VALUES (?,?)', (event['patient'], mode))
                    return self.reply(200, {'configured': True})
                if self.path != '/identity-results':
                    return self.reply(404, {'error': 'NOT_FOUND'})
                if (event['schemaVersion'] != 1 or
                        event['action'] not in ('LINK', 'SEPARATE', 'REJECT', 'UNDO') or
                        event['kind'] != ('CORRECTION' if event['action'] == 'UNDO' else 'APPROVAL') or
                        not isinstance(event['caseVersion'], int) or event['caseVersion'] < 1 or
                        not isinstance(event['sourceVersion'], int) or event['sourceVersion'] < 1):
                    raise ValueError('EVENT_INVALID')
                for key in ('eventId', 'caseId', 'sourceSystem', 'sourcePatientId', 'occurredAt'):
                    if not isinstance(event[key], str) or not event[key] or len(event[key]) > 500:
                        raise ValueError('EVENT_INVALID')
                if any(not isinstance(event[k], str) for k in ('masterId', 'previousMasterId')):
                    raise ValueError('EVENT_INVALID')
                if self.headers.get('Idempotency-Key') != event['eventId']:
                    raise ValueError('IDEMPOTENCY_KEY_REQUIRED')
            except (KeyError, TypeError, ValueError):
                return self.reply(400, {'error': 'INVALID_REQUEST'})

            canonical = json.dumps(event, sort_keys=True, separators=(',', ':'))
            with sqlite3.connect(database, timeout=10) as db:
                # Serialize lookup and effect in one durable transaction, including concurrent duplicates.
                db.execute('BEGIN IMMEDIATE')
                db.execute('INSERT INTO attempts VALUES (?,1) ON CONFLICT(id) DO UPDATE SET count=count+1', (event['eventId'],))
                attempt = db.execute('SELECT count FROM attempts WHERE id=?', (event['eventId'],)).fetchone()[0]
                row = db.execute('SELECT mode FROM controls WHERE patient=?', (event['sourcePatientId'],)).fetchone()
                mode = row[0] if row else 'normal'
                if mode == 'always-fail' or (mode == 'fail-once' and attempt == 1):
                    status, receipt = 503, {'error': 'SYNTHETIC_UNAVAILABLE'}
                else:
                    saved = db.execute('SELECT payload,receipt FROM events WHERE id=?', (event['eventId'],)).fetchone()
                    if saved and saved[0] != canonical:
                        status, receipt = 409, {'error': 'EVENT_ID_CONFLICT'}
                    elif saved:
                        status, receipt = 200, {'eventId': event['eventId'], 'status': 'DUPLICATE', 'receiptId': saved[1]}
                    else:
                        previous = db.execute('SELECT case_id,version FROM mappings WHERE source=? AND patient=?',
                                              (event['sourceSystem'], event['sourcePatientId'])).fetchone()
                        if previous and previous[0] == event['caseId'] and previous[1] >= event['caseVersion']:
                            status, receipt = 409, {'error': 'STALE_CASE_VERSION'}
                        else:
                            receipt_id = 'his-' + str(uuid.uuid4())
                            db.execute('INSERT INTO events VALUES (?,?,?)', (event['eventId'], canonical, receipt_id))
                            db.execute('INSERT OR REPLACE INTO mappings VALUES (?,?,?,?,?)',
                                       (event['sourceSystem'], event['sourcePatientId'], event['caseId'], event['caseVersion'], event['masterId']))
                            status, receipt = 200, {'eventId': event['eventId'], 'status': 'ACCEPTED', 'receiptId': receipt_id}
            # Commit before dropping or corrupting a receipt, reproducing the ambiguous-delivery window.
            if attempt == 1:
                if mode == 'drop-once':
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if mode == 'wrong-ack-once':
                    receipt['eventId'] = 'wrong-event'
                if mode == 'missing-receipt-once':
                    receipt.pop('receiptId', None)
                if mode == 'malformed-once':
                    receipt = ['invalid-receipt']
                if mode == 'invalid-status-once':
                    receipt['status'] = 'QUEUED'
                if mode == 'http-error-once':
                    status = 503
                if mode == 'oversized-once':
                    receipt['padding'] = 'x' * 8193
                if mode == 'wrong-id-type-once':
                    receipt['eventId'] = 123
                if mode == 'long-receipt-once':
                    receipt['receiptId'] = 'x' * 201
                if mode == 'empty-receipt-once':
                    receipt['receiptId'] = ''
                if mode == 'slow-once':
                    time.sleep(1)
            self.reply(status, receipt)

    return ThreadingHTTPServer((host, port), Handler)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=18894)
    parser.add_argument('--database', required=True)
    args = parser.parse_args()
    make_server('127.0.0.1', args.port, args.database).serve_forever()
