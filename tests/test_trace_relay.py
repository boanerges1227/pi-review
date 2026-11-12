"""Exercise the metadata relay with real local HTTP servers and private payloads."""
import concurrent.futures
import contextlib
import http.client
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

MODULE = Path(__file__).parents[1] / 'python' / 'trace_relay.py'


@contextlib.contextmanager
def upstream(responses=None):
    """Serve scripted replies and retain wire input only within each test."""
    requests = []
    replies = list(responses or [(200, {'usage': {'prompt_tokens': 3, 'completion_tokens': 2}})])
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers['Content-Length']))
            with lock:
                requests.append((self.path, dict(self.headers), body))
                item = replies.pop(0) if len(replies) > 1 else replies[0]
            if item is None:
                self.connection.shutdown(2)
                self.connection.close()
                return
            status, payload = item[:2]
            if len(item) > 2:
                time.sleep(item[2])
            raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(status)
            response_headers = item[3] if len(item) > 3 else {}
            self.send_header('Content-Type', response_headers.get('Content-Type', 'application/json'))
            for name, value in response_headers.items():
                if name.lower() != 'content-type':
                    self.send_header(name, value)
            self.send_header('Location', 'https://secret.invalid/key=secret')
            self.send_header('Set-Cookie', 'secret=private')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.wfile.write(raw)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}', requests
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


def post(relay, payload=None, headers=None, path=None, method='POST', raw=None):
    """Call the real loopback relay and return a complete wire reply."""
    target = urlsplit(relay.base_url)
    connection = http.client.HTTPConnection(target.hostname, target.port, timeout=5)
    data = raw if raw is not None else json.dumps(payload or {'model': 'model-test', 'messages': [{'content': 'prompt-secret'}]}).encode()
    connection.request(method, path or target.path + 'chat/completions?request=private-query', data, headers or {'Content-Type': 'application/json'})
    reply = connection.getresponse()
    result = reply.status, dict(reply.getheaders()), reply.read()
    connection.close()
    return result


class RelayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if MODULE.exists():
            spec = importlib.util.spec_from_file_location('trace_relay_under_test', MODULE)
            cls.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.module)
        else:
            cls.module = None

    def setUp(self):
        self.assertIsNotNone(self.module, 'The metadata-only Relay implementation must exist')

    def relay(self, url, timeout=2):
        instance = self.module.Relay(url, timeout)
        self.addCleanup(instance.close)
        return instance

    def test_forwards_exact_wire_data_and_only_allowlisted_headers(self):
        with upstream() as (url, requests):
            relay = self.relay(url + '/gateway/v1?tenant=private-tenant')
            status, headers, _ = post(relay, headers={'Authorization': 'Bearer key-secret', 'x-api-key': 'key-secret', 'anthropic-version': '2023-06-01', 'anthropic-beta': 'tools', 'OpenAI-Organization': 'org-secret', 'Content-Type': 'application/json', 'Accept': 'application/json', 'Proxy-Authorization': 'proxy-secret', 'X-Private': 'header-secret', 'Host': 'evil.invalid'})
            self.assertEqual(status, 200)
            self.assertEqual(requests[0][0], '/gateway/v1/chat/completions?tenant=private-tenant&request=private-query')
            actual = {key.lower(): value for key, value in requests[0][1].items()}
            for key in ('authorization', 'x-api-key', 'anthropic-version', 'anthropic-beta', 'openai-organization'):
                self.assertIn(key, actual)
            for key in ('proxy-authorization', 'x-private'):
                self.assertNotIn(key, actual)
            self.assertNotEqual(actual['host'], 'evil.invalid')
            self.assertIn(b'prompt-secret', requests[0][2])
            self.assertNotIn('Location', headers)
            self.assertNotIn('Set-Cookie', headers)
            events = relay.drain()
            self.assertEqual([event['kind'] for event in events], ['model.request', 'model.response'])
            self.assertEqual([event['sequence'] for event in events], [1, 2])
            self.assertEqual(events[0]['spanId'], events[1]['spanId'])
            event = events[1]
            self.assertEqual((event['inputTokens'], event['outputTokens'], event['usageKnown']), (3, 2, True))
            self.assertEqual(event['status'], 'OK')
            self.assertEqual(event['httpStatus'], 200)
            self.assertRegex(event['startedAt'], r'\.\d{6}Z$')
            self.assertRegex(event['endedAt'], r'\.\d{6}Z$')
            self.assertGreaterEqual(event['durationMs'], 0)
            serialized = json.dumps(events)
            for secret in ('prompt-secret', 'key-secret', 'org-secret', 'private-query', 'private-tenant', 'header-secret', 'gateway', '127.0.0.1'):
                self.assertNotIn(secret, serialized)
            self.assertEqual(relay.drain(), [])

    def test_retry_and_content_headers_survive_without_entering_metadata(self):
        allowed = {
            'Content-Type': 'application/problem+json; charset=utf-8',
            'Retry-After': '1', 'retry-after-ms': '125', 'x-should-retry': 'true',
            'x-ratelimit-remaining-requests': '0', 'x-ratelimit-reset-requests': '2s',
            'x-request-id': 'private-request-id',
        }
        blocked = {'X-Private': 'response-header-secret', 'Proxy-Authenticate': 'private-proxy'}
        payload = {'error': 'response-secret'}
        with upstream([(429, payload, 0, dict(allowed, **blocked))]) as (url, _):
            relay = self.relay(url)
            status, headers, raw = post(relay)
            self.assertEqual(status, 429)
            actual = {key.lower(): value for key, value in headers.items()}
            for key, value in allowed.items():
                self.assertEqual(actual.get(key.lower()), value)
            self.assertEqual(int(actual['content-length']), len(raw))
            self.assertEqual(json.loads(raw), payload)
            for key in ('location', 'set-cookie', 'x-private', 'proxy-authenticate'):
                self.assertNotIn(key, actual)
            events = json.dumps(relay.drain())
            for marker in ('private-request-id', 'response-header-secret', 'response-secret', 'retry-after', 'x-should-retry'):
                self.assertNotIn(marker, events)

    def test_connection_phase_uses_ten_second_cap_before_request_timeout(self):
        # A deterministic connection double avoids flaky external network waits.
        # The existing loopback timeout test separately exercises real socket I/O.
        for scheme, timeout, expected in [('http', 110, 10), ('https', 110, 10), ('http', 2, 2)]:
            with self.subTest(scheme=scheme, timeout=timeout):
                target, _ = self.module._configuration(scheme + '://localhost/v1', timeout)
                state = self.module._State(target, timeout)
                handler = self.module._Handler.__new__(self.module._Handler)
                handler.headers = {'Content-Type': 'application/json'}
                replies = []
                handler._reply = lambda *args: replies.append(args)
                body = b'{"model":"model-test"}'
                attempt = state.begin(body, 'chat/completions', 'model-test')
                connection = mock.MagicMock()
                response = connection.getresponse.return_value
                response.status = 200
                response.getheader.return_value = 'application/json'
                response.getheaders.return_value = [('Content-Type', 'application/json')]
                response.read.return_value = b'{}'
                name = 'HTTPSConnection' if scheme == 'https' else 'HTTPConnection'
                with mock.patch.object(self.module.http.client, name, return_value=connection) as factory:
                    handler._forward(state, urlsplit('chat/completions'), body, attempt)
                self.assertEqual(factory.call_args.kwargs['timeout'], expected)
                connection.connect.assert_called_once_with()
                connection.sock.settimeout.assert_called_once_with(timeout)
                calls = connection.mock_calls
                self.assertLess(calls.index(mock.call.connect()), calls.index(mock.call.sock.settimeout(timeout)))
                request_position = next(index for index, call in enumerate(calls) if call[0] == 'request')
                self.assertLess(calls.index(mock.call.sock.settimeout(timeout)), request_position)
                self.assertEqual(replies[0][0], 200)
                self.assertEqual(state.drain()[-1]['status'], 'OK')

    def test_anthropic_usage_and_both_tool_call_formats(self):
        replies = [(200, {'usage': {'input_tokens': 7, 'output_tokens': 4}, 'content': [{'type': 'tool_use'}, {'type': 'text'}]}), (200, {'usage': {'prompt_tokens': 5, 'completion_tokens': 6}, 'choices': [{'message': {'tool_calls': [{}, {}]}}]})]
        with upstream(replies) as (url, _):
            relay = self.relay(url)
            post(relay)
            post(relay)
            responses = [event for event in relay.drain() if event['kind'] == 'model.response']
            self.assertEqual([(event['inputTokens'], event['outputTokens'], event['toolCallCount']) for event in responses], [(7, 4, 1), (5, 6, 2)])

    def test_unknown_or_invalid_usage_never_invents_token_counts(self):
        for payload in ({}, {'usage': {'input_tokens': 1}}, {'usage': {'input_tokens': True, 'output_tokens': 2}}, {'usage': {'prompt_tokens': -1, 'completion_tokens': 2}}, b'not json response-secret'):
            with self.subTest(payload=payload), upstream([(200, payload)]) as (url, _):
                relay = self.relay(url)
                self.assertEqual(post(relay)[0], 200)
                event = relay.drain()[-1]
                self.assertIs(event['usageKnown'], False)
                self.assertNotIn('inputTokens', event)
                self.assertNotIn('outputTokens', event)

    def test_retries_link_identical_failed_attempt_without_exposing_body_hash(self):
        with upstream([(429, {'error': 'response-secret'}), (200, {})]) as (url, _):
            relay = self.relay(url)
            self.assertEqual(post(relay)[0], 429)
            self.assertEqual(post(relay)[0], 200)
            events = relay.drain()
            self.assertEqual(events[1]['status'], 'FAILED')
            self.assertEqual(events[1]['errorCode'], 'UPSTREAM_HTTP_ERROR')
            self.assertEqual(events[2]['retryOf'], events[0]['spanId'])
            self.assertEqual(events[2]['retryKind'], 'identical-after-failure')
            self.assertNotIn('hash', json.dumps(events).lower())
            post(relay)
            self.assertNotIn('retryOf', relay.drain()[0])

    def test_network_failures_and_redirects_are_observed_without_sensitive_details(self):
        with upstream([None, (302, {'secret': 'response-secret'})]) as (url, _):
            relay = self.relay(url)
            for expected in ('UPSTREAM_NETWORK_ERROR', 'UPSTREAM_REDIRECT'):
                status, headers, body = post(relay)
                self.assertEqual(status, 502)
                self.assertNotIn('Location', headers)
                self.assertNotIn(b'response-secret', body)
                event = relay.drain()[-1]
                self.assertEqual(event['errorCode'], expected)
                self.assertEqual(event['status'], 'FAILED')

    def test_nonce_method_and_json_rejections_do_not_reach_upstream(self):
        with upstream() as (url, requests):
            relay = self.relay(url)
            self.assertEqual(urlsplit(relay.base_url).hostname, '127.0.0.1')
            self.assertGreaterEqual(len(urlsplit(relay.base_url).path), 32)
            for kwargs, expected in [({'path': '/wrong/chat/completions'}, 404), ({'method': 'GET'}, 405), ({'method': 'PUT'}, 405), ({'raw': b'{broken'}, 400), ({'raw': b'[]'}, 400), ({'payload': {'stream': True}}, 501), ({'path': urlsplit(relay.base_url).path + '../escape'}, 400), ({'path': urlsplit(relay.base_url).path + '//[invalid'}, 400), ({'raw': b'', 'headers': {'Content-Length': '9' * 5000}}, 413)]:
                self.assertEqual(post(relay, **kwargs)[0], expected)
            self.assertEqual(requests, [])
            self.assertEqual(relay.drain(), [])

    def test_request_response_and_lifetime_call_bounds(self):
        with upstream([(200, b'x' * (8 * 1024 * 1024 + 1))]) as (url, requests):
            relay = self.relay(url)
            self.assertEqual(post(relay, raw=b'', headers={'Content-Length': str(8 * 1024 * 1024 + 1)})[0], 413)
            self.assertEqual(requests, [])
            self.assertEqual(post(relay)[0], 502)
            self.assertEqual(relay.drain()[-1]['errorCode'], 'UPSTREAM_RESPONSE_TOO_LARGE')
        with upstream() as (url, requests):
            relay = self.relay(url)
            for _ in range(32):
                self.assertEqual(post(relay)[0], 200)
            self.assertEqual(post(relay)[0], 429)
            self.assertEqual(len(requests), 32)
            self.assertEqual(len(relay.drain()), 64)
            self.assertEqual(post(relay)[0], 429)

    def test_concurrent_attempts_keep_distinct_spans_and_monotonic_event_sequence(self):
        with upstream([(200, {}, 0.03)]) as (url, requests):
            relay = self.relay(url)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                statuses = list(pool.map(lambda _: post(relay)[0], range(12)))
            self.assertEqual(statuses, [200] * 12)
            events = relay.drain()
            self.assertEqual([event['sequence'] for event in events], list(range(1, 25)))
            self.assertEqual(len({event['spanId'] for event in events}), 12)
            self.assertEqual(len(requests), 12)

    def test_child_process_reaped_and_metadata_remains_drainable_after_close(self):
        with upstream() as (url, _):
            relay = self.relay(url + '/private-config?key=configuration-secret')
            process = relay._process
            self.assertIsNone(process.poll())
            self.assertNotEqual(process.pid, os.getpid())
            self.assertNotIn('configuration-secret', ' '.join(process.args))
            self.assertEqual(post(relay)[0], 200)
            relay.close()
            self.assertIsNotNone(process.poll())
            self.assertEqual(len(relay.drain()), 2)
            self.assertEqual(relay.drain(), [])

    def test_orphan_child_closes_credential_listener(self):
        program = (
            'import sys; sys.path.insert(0, sys.argv[1]); '
            'from trace_relay import Relay; '
            'relay=Relay("http://127.0.0.1:1"); '
            'print(relay.base_url,flush=True)'
        )
        parent = subprocess.Popen([sys.executable, '-c', program, str(MODULE.parent)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            base_url = parent.stdout.readline().strip()
            self.assertTrue(base_url.startswith('http://127.0.0.1:'))
            self.assertEqual(parent.wait(timeout=5), 0)
            target = urlsplit(base_url)
            deadline = time.monotonic() + 4
            closed = False
            while time.monotonic() < deadline:
                connection = http.client.HTTPConnection(target.hostname, target.port, timeout=0.2)
                try:
                    connection.request('GET', '/')
                    connection.getresponse().read()
                except OSError:
                    closed = True
                    break
                finally:
                    connection.close()
                time.sleep(0.05)
            self.assertTrue(closed, 'Orphan child must release its listener')
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=5)
            parent.stdout.close()
            parent.stderr.close()

    def test_network_timeout_is_sanitized(self):
        with upstream([(200, {}, 0.2)]) as (url, _):
            relay = self.relay(url, timeout=0.05)
            self.assertEqual(post(relay)[0], 502)
            event = relay.drain()[-1]
            self.assertEqual(event['errorCode'], 'UPSTREAM_NETWORK_ERROR')
            self.assertIsNone(event['httpStatus'])
            self.assertFalse(event['usageKnown'])

    def test_configuration_validation_and_idempotent_close(self):
        for url in ('file:///tmp/private', 'https://user:secret@example.com', 'http://example.com/#secret', 'http://example.com/#', 'http://', 'http://example.com:wrong', 'http://example.com/\nsecret'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.module.Relay(url)
        for timeout in (0, -1, float('inf'), float('nan')):
            with self.assertRaises(ValueError):
                self.module.Relay('http://127.0.0.1', timeout)
        with upstream() as (url, _):
            relay = self.relay(url)
            relay.close()
            relay.close()
            with self.assertRaises(OSError):
                post(relay)
            self.assertEqual(relay.drain(), [])


if __name__ == '__main__':
    unittest.main()
