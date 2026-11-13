"""Exercise the synthetic receiver over real HTTP and durable SQLite storage."""
import concurrent.futures
import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path

try:
    from mock_his import make_server
except ModuleNotFoundError:
    make_server = None


class MockHISTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(make_server, 'Synthetic HIS receiver is not implemented')
        self.directory = tempfile.TemporaryDirectory()
        self.path = str(Path(self.directory.name) / 'his.sqlite')
        self.start()

    def start(self):
        self.server = make_server('127.0.0.1', 0, self.path)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def tearDown(self):
        self.stop()
        self.directory.cleanup()

    def request(self, method, path, data=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        headers = {'Content-Type': 'application/json'}
        if data and 'eventId' in data:
            headers['Idempotency-Key'] = data['eventId']
        try:
            conn.request(method, path, json.dumps(data) if data is not None else None, headers)
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def event(self):
        return {'schemaVersion': 1, 'eventId': 'test-event-1', 'caseId': 'c1',
                'caseVersion': 2, 'sourceSystem': 'HIS', 'sourcePatientId': 'synthetic-p1',
                'sourceVersion': 1, 'kind': 'APPROVAL', 'action': 'LINK',
                'previousMasterId': '', 'masterId': 'm1', 'occurredAt': '2026-11-13T00:00:00Z'}

    def test_duplicate_receipt_survives_receiver_restart(self):
        event = self.event()
        status, accepted = self.request('POST', '/identity-results', event)
        self.assertEqual(status, 200)
        self.assertEqual(accepted['status'], 'ACCEPTED')
        self.stop()
        self.start()
        _, duplicate = self.request('POST', '/identity-results', event)
        self.assertEqual(duplicate['status'], 'DUPLICATE')
        self.assertEqual(duplicate['receiptId'], accepted['receiptId'])
        _, stats = self.request('GET', '/__test/state')
        self.assertEqual(stats['accepted'], 1)
        self.assertEqual(stats['attempts'], 2)

    def test_same_event_id_with_changed_payload_is_rejected(self):
        event = self.event()
        self.request('POST', '/identity-results', event)
        event['masterId'] = 'm2'
        status, _ = self.request('POST', '/identity-results', event)
        self.assertEqual(status, 409)
        _, stats = self.request('GET', '/__test/state')
        self.assertEqual(stats['accepted'], 1)
        self.assertEqual(stats['mappings'][0]['masterId'], 'm1')

    def test_concurrent_duplicate_requests_apply_once(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(lambda _: self.request('POST', '/identity-results', self.event()), range(5)))
        self.assertEqual(sum(r[1]['status'] == 'ACCEPTED' for r in results), 1)
        self.assertEqual(len({r[1]['receiptId'] for r in results}), 1)

    def test_lost_receipt_does_not_repeat_business_effect(self):
        self.request('POST', '/__test/control', {'patient': 'synthetic-p1', 'mode': 'drop-once'})
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request('POST', '/identity-results', self.event())
        _, receipt = self.request('POST', '/identity-results', self.event())
        self.assertEqual(receipt['status'], 'DUPLICATE')
        _, stats = self.request('GET', '/__test/state')
        self.assertEqual(stats['accepted'], 1)

    def test_old_case_version_cannot_overwrite_correction(self):
        event = self.event()
        self.request('POST', '/identity-results', event)
        correction = dict(event, eventId='undo-1', caseVersion=3, kind='CORRECTION', action='UNDO', masterId='')
        self.request('POST', '/identity-results', correction)
        late = dict(event, eventId='late-1')
        status, _ = self.request('POST', '/identity-results', late)
        self.assertEqual(status, 409)
        _, stats = self.request('GET', '/__test/state')
        self.assertEqual(stats['mappings'][0]['masterId'], '')


if __name__ == '__main__':
    unittest.main()
