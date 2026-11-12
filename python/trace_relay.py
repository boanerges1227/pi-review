"""Observe non-streaming native SDK HTTP attempts without retaining content.

The HTTP server runs in a separate Python process: native IRIS/Rust calls may
hold Embedded Python's GIL. Only sanitized metadata crosses back to the parent.
Configuration and wire bodies remain in RAM, never in argv, files, or logs.
Each worker retains the native SDK's 10-second connect/TLS cap and configured
request/read timeout (110 seconds by default). Smaller timeouts cap both phases.
"""
import contextlib
from datetime import datetime, timezone
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
import re
import secrets
import selectors
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import unquote, urlsplit

_MAX_BODY = 8 * 1024 * 1024
_MAX_CALLS = 32
_MAX_LIFETIME = 150
_FORWARD_HEADERS = frozenset({
    'authorization', 'x-api-key', 'anthropic-version', 'anthropic-beta',
    'openai-organization', 'content-type', 'accept',
})
_RESPONSE_HEADERS = frozenset({
    'content-type', 'retry-after', 'retry-after-ms', 'x-should-retry',
    'x-ratelimit-limit-requests', 'x-ratelimit-limit-tokens',
    'x-ratelimit-remaining-requests', 'x-ratelimit-remaining-tokens',
    'x-ratelimit-reset-requests', 'x-ratelimit-reset-tokens',
    'request-id', 'x-request-id',
})
_MODEL = re.compile(r'[A-Za-z0-9._:/-]{1,128}\Z')


def _configuration(upstream_url, timeout):
    """Reject ambiguous upstream addresses without echoing private input."""
    try:
        if not isinstance(upstream_url, str) or len(upstream_url) > 8192:
            raise ValueError
        if any(ord(char) <= 32 or ord(char) == 127 for char in upstream_url):
            raise ValueError
        target = urlsplit(upstream_url)
        if target.scheme not in ('http', 'https') or not target.hostname:
            raise ValueError
        if target.username is not None or target.password is not None or '#' in upstream_url:
            raise ValueError
        target.port
        seconds = float(timeout)
        if isinstance(timeout, bool) or not math.isfinite(seconds) or seconds <= 0 :
            raise ValueError
        return target, seconds
    except (TypeError, ValueError):
        raise ValueError('INVALID_RELAY_CONFIGURATION') from None


def _utc():
    """Return a metadata timestamp independent of local timezone settings."""
    return datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')


def _response_metadata(raw):
    """Extract only validated token totals and counts, never message content."""
    result = {'usageKnown': False, 'toolCallCount': 0}
    try:
        data = json.loads(raw)
        if not isinstance(data, dict):
            return result
        usage = data.get('usage')
        if isinstance(usage, dict):
            pair = ('prompt_tokens', 'completion_tokens') if 'prompt_tokens' in usage else ('input_tokens', 'output_tokens')
            values = [usage.get(key) for key in pair]
            if all(type(value) is int and 0 <= value <= 2**53 - 1 for value in values):
                result.update(usageKnown=True, inputTokens=values[0], outputTokens=values[1])
        content = data.get('content')
        if isinstance(content, list):
            result['toolCallCount'] += sum(isinstance(item, dict) and item.get('type') == 'tool_use' for item in content)
        choices = data.get('choices')
        if isinstance(choices, list):
            for choice in choices:
                message = choice.get('message') if isinstance(choice, dict) else None
                if isinstance(message, dict):
                    tools = message.get('tool_calls')
                    if isinstance(tools, list):
                        result['toolCallCount'] += len(tools)
                    elif isinstance(message.get('function_call'), dict):
                        result['toolCallCount'] += 1
    except (ValueError, TypeError, RecursionError):
        pass
    return result


class Relay:
    """Own one short-lived credential relay process and drain its metadata."""

    def __init__(self, upstream_url: str, timeout: float = 110):
        """Start a loopback child using private pipes for configuration only."""
        _, seconds = _configuration(upstream_url, timeout)
        self._api_lock = threading.RLock()
        self._closed = False
        self._pending = []
        executable = sys.executable
        if not executable or 'python' not in os.path.basename(executable).lower():
            executable = shutil.which('python3')
        if not executable:
            raise RuntimeError('TRACE_RELAY_PYTHON_UNAVAILABLE')
        self._process = subprocess.Popen(
            [executable, os.path.abspath(__file__), '--serve'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        try:
            config = json.dumps({'upstream': upstream_url, 'timeout': seconds, 'parent': os.getpid()}).encode() + b'\n'
            self._process.stdin.write(config)
            self._process.stdin.flush()
            with selectors.DefaultSelector() as ready:
                ready.register(self._process.stdout, selectors.EVENT_READ)
                if not ready.select(5):
                    raise RuntimeError
            line = self._process.stdout.readline(4096)
            info = json.loads(line)
            self._port = int(info['port'])
            self._control = info['control']
            self.base_url = f"http://127.0.0.1:{self._port}/{info['nonce']}/"
        except Exception:
            self._stop()
            raise RuntimeError('TRACE_RELAY_START_FAILED') from None

    def _control_call(self, action):
        """Read sanitized child state over a distinct random control path."""
        connection = http.client.HTTPConnection('127.0.0.1', self._port, timeout=3)
        try:
            connection.request('POST', f'/{self._control}/{action}', body=b'')
            response = connection.getresponse()
            raw = response.read(128 * 1024)
            if response.status != 200:
                raise RuntimeError
            return json.loads(raw)
        except Exception:
            raise RuntimeError('TRACE_RELAY_UNAVAILABLE') from None
        finally:
            connection.close()

    def drain(self) -> list[dict]:
        """Atomically transfer queued metadata, including data saved on close."""
        with self._api_lock:
            events, self._pending = self._pending, []
            if not self._closed:
                events.extend(self._control_call('drain'))
            return events

    def _stop(self):
        """Reap only this instance's child, with bounded shutdown waits."""
        if self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=2)
        for pipe in (self._process.stdin, self._process.stdout):
            if pipe:
                pipe.close()

    def close(self):
        """Preserve final metadata and idempotently release the private process."""
        with self._api_lock:
            if self._closed:
                return
            with contextlib.suppress(RuntimeError):
                self._pending.extend(self._control_call('drain'))
            self._closed = True
            self._stop()


class _State:
    """Keep bounded events and retry fingerprints inside the child process."""

    def __init__(self, target, timeout):
        self.target = target
        self.timeout = timeout
        self.nonce = secrets.token_urlsafe(32)
        self.control = secrets.token_urlsafe(32)
        self.salt = secrets.token_bytes(32)
        self.lock = threading.Lock()
        self.events = []
        self.calls = 0
        self.sequence = 0
        self.previous = {}

    def begin(self, body, path, model):
        """Reserve exactly two event slots before attempting any upstream I/O."""
        fingerprint = hashlib.sha256(self.salt + path.encode() + b'\0' + body).digest()
        with self.lock:
            if self.calls >= _MAX_CALLS:
                return None
            self.calls += 1
            metadata = {'spanId': f'http-{self.calls}', 'startedAt': _utc(), 'usageKnown': False}
            if isinstance(model, str) and _MODEL.fullmatch(model):
                metadata['model'] = model
            previous = self.previous.get(fingerprint)
            if previous and previous[1]:
                metadata.update(retryOf=previous[0], retryKind='identical-after-failure')
            self._append(dict(metadata, kind='model.request'))
            return metadata, fingerprint, time.monotonic()

    def _append(self, event):
        """Assign event order under the same lock as queue mutation."""
        self.sequence += 1
        event['sequence'] = self.sequence
        self.events.append(event)

    def finish(self, attempt, status, code, raw):
        """Publish whitelisted response metadata after every actual attempt."""
        metadata, fingerprint, started = attempt
        failed = bool(code)
        event = dict(metadata, kind='model.response', endedAt=_utc(),
                     durationMs=round((time.monotonic() - started) * 1000, 3),
                     status='FAILED' if failed else 'OK', errorCode=code,
                     httpStatus=status, **_response_metadata(raw))
        with self.lock:
            self._append(event)
            self.previous[fingerprint] = (metadata['spanId'], failed)

    def drain(self):
        """Empty the sanitized queue without exposing configuration or hashes."""
        with self.lock:
            events, self.events = self.events, []
            return events


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def handle_error(self, request, client_address):
        """Suppress default tracebacks, which can contain private wire input."""


class _Handler(BaseHTTPRequestHandler):
    """Accept only nonce-scoped POST JSON for the current non-streaming SDK."""

    def log_message(self, *args):
        """Disable HTTP access logs, including private paths and query strings."""

    def setup(self):
        """Bound client reads before parsing request headers or payloads."""
        super().setup()
        self.connection.settimeout(self.server.state.timeout)

    def send_error(self, code, message=None, explain=None):
        """Return fixed errors even when BaseHTTPRequestHandler rejects input."""
        self._reply(405 if code == 501 else code, b'{"error":"INVALID_REQUEST"}')

    def _reply(self, status, raw, response_headers=None):
        """Preserve safe SDK response hints and generate correct body framing."""
        with contextlib.suppress(OSError):
            self.send_response(status)
            response_headers = response_headers or {}
            self.send_header('Content-Type', response_headers.get('content-type', 'application/json'))
            for name, value in response_headers.items():
                if name != 'content-type':
                    self.send_header(name, value)
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(raw)
        self.close_connection = True

    def _reject(self, status, code):
        """Keep all locally generated error bodies constant and content-free."""
        self._reply(status, json.dumps({'error': code}).encode())

    def _dispatch(self):
        """Validate capability, path, framing, and JSON before upstream I/O."""
        state = self.server.state
        if self.command == 'POST' and self.path == f'/{state.control}/drain':
            self._reply(200, json.dumps(state.drain()).encode())
            return
        prefix = f'/{state.nonce}/'
        if not self.path.startswith(prefix):
            self._reject(404, 'NOT_FOUND')
            return
        if self.command != 'POST':
            self._reject(405, 'METHOD_NOT_ALLOWED')
            return
        suffix = self.path[len(prefix):]
        try:
            parsed = urlsplit(suffix)
            decoded = unquote(parsed.path)
        except ValueError:
            self._reject(400, 'INVALID_PATH')
            return
        if parsed.scheme or parsed.netloc or parsed.fragment or '\\' in decoded or any(part in ('.', '..') for part in decoded.split('/')):
            self._reject(400, 'INVALID_PATH')
            return
        lengths = self.headers.get_all('Content-Length', [])
        if self.headers.get('Transfer-Encoding') or len(lengths) != 1 or not lengths[0].isdigit():
            self._reject(400, 'INVALID_FRAMING')
            return
        if len(lengths[0]) > len(str(_MAX_BODY)):
            self._reject(413, 'REQUEST_TOO_LARGE')
            return
        size = int(lengths[0])
        if size > _MAX_BODY:
            self._reject(413, 'REQUEST_TOO_LARGE')
            return
        try:
            body = self.rfile.read(size)
            data = json.loads(body)
            if len(body) != size or not isinstance(data, dict):
                raise ValueError
        except (ValueError, OSError, RecursionError):
            self._reject(400, 'INVALID_JSON')
            return
        if data.get('stream'):
            self._reject(501, 'STREAMING_UNSUPPORTED')
            return
        attempt = state.begin(body, suffix, data.get('model'))
        if attempt is None:
            self._reject(429, 'CALL_LIMIT_REACHED')
            return
        self._forward(state, parsed, body, attempt)

    def _forward(self, state, suffix, body, attempt):
        """Perform one verified HTTP/HTTPS request without following redirects."""
        target = state.target
        path = (target.path.rstrip('/') + '/' + suffix.path)
        query = '&'.join(part for part in (target.query, suffix.query) if part)
        if query:
            path += '?' + query
        headers = {name: value for name, value in self.headers.items() if name.lower() in _FORWARD_HEADERS}
        connection_class = http.client.HTTPSConnection if target.scheme == 'https' else http.client.HTTPConnection
        connection = connection_class(target.hostname, target.port, timeout=min(10, state.timeout))
        status, code, raw = None, 'UPSTREAM_NETWORK_ERROR', b''
        downstream_status = 502
        response_headers = {}
        try:
            # HTTPSConnection.connect includes TLS negotiation under the same cap.
            connection.connect()
            connection.sock.settimeout(state.timeout)
            connection.request('POST', path, body=body, headers=headers)
            response = connection.getresponse()
            status = response.status
            if 300 <= status < 400:
                code = 'UPSTREAM_REDIRECT'
            elif 'text/event-stream' in response.getheader('Content-Type', '').lower():
                code = 'UPSTREAM_STREAMING_UNSUPPORTED'
            else:
                raw = response.read(_MAX_BODY + 1)
                if len(raw) > _MAX_BODY:
                    raw = b''
                    code = 'UPSTREAM_RESPONSE_TOO_LARGE'
                else:
                    code = 'UPSTREAM_HTTP_ERROR' if status >= 400 else ''
                    downstream_status = status
                    # These hints affect native SDK retries; never add them to events.
                    for name, value in response.getheaders():
                        key = name.lower()
                        if key in _RESPONSE_HEADERS and 0 < len(value) <= 256 and all(32 <= ord(char) < 127 for char in value):
                            response_headers[key] = value
        except (OSError, http.client.HTTPException, ValueError):
            raw = b''
            code = 'UPSTREAM_NETWORK_ERROR'
        finally:
            connection.close()
            state.finish(attempt, status, code, raw)
        if downstream_status == 502 and code != 'UPSTREAM_HTTP_ERROR':
            self._reject(502, code)
        else:
            self._reply(downstream_status, raw, response_headers)

    do_POST = _dispatch
    do_GET = _dispatch
    do_PUT = _dispatch
    do_DELETE = _dispatch
    do_PATCH = _dispatch
    do_HEAD = _dispatch
    do_OPTIONS = _dispatch


def _serve():
    """Run the child with an orphan watchdog and a fixed maximum lifetime."""
    config = json.loads(sys.stdin.buffer.readline(16384))
    target, timeout = _configuration(config['upstream'], config['timeout'])
    parent = config['parent']
    if type(parent) is not int or parent != os.getppid():
        return
    server = _Server(('127.0.0.1', 0), _Handler)
    server.state = _State(target, timeout)
    stopped = threading.Event()

    def watchdog():
        """Remove the credential bridge if its parent dies or its lease expires."""
        deadline = time.monotonic() + _MAX_LIFETIME
        while not stopped.wait(0.25):
            if os.getppid() != parent or time.monotonic() >= deadline:
                server.shutdown()
                return

    threading.Thread(target=watchdog, daemon=True, name='trace-relay-watchdog').start()
    print(json.dumps({'port': server.server_port, 'nonce': server.state.nonce, 'control': server.state.control}), flush=True)
    # Drop the original configuration object as soon as startup completes.
    del config
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        stopped.set()
        server.server_close()


if __name__ == '__main__' and sys.argv[1:] == ['--serve']:
    with contextlib.suppress(Exception):
        _serve()
