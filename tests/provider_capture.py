"""PITEST-only local HTTP transport fixture: capture the SDK's actual model selection without external model calls."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import os
import signal
import subprocess
import sys
import time

ROOT = Path('/tmp/pi-synthetic-provider')
PORT = 18541


class Capture(BaseHTTPRequestHandler):
    def do_POST(self):
        """Capture the actual model and prompt in synthetic requests and return a fixed transport response without simulating business decisions."""
        # Accept only test placeholder credentials; reject real keys without writing them to disk.
        if self.headers.get('Authorization') != 'Bearer unused':
            self.send_error(403)
            return
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        prompts = [m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'system']
        ROOT.with_suffix('.capture.json').write_text(json.dumps({'model': body.get('model'), 'systemPrompts': prompts}))
        data = json.dumps({'id': 'synthetic-transport-fixture', 'object': 'chat.completion', 'model': body.get('model'), 'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'synthetic transport fixture only'}, 'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        """Disable default access logging so credentials or messages cannot enter test output."""
        # Keep request paths, messages, and credentials out of test logs.
        pass


def stop():
    """Terminate only a child whose command-line identity matches this fixture to avoid killing a reused process ID."""
    pidfile = ROOT.with_suffix('.pid')
    if pidfile.exists():
        pid = int(pidfile.read_text())
        command = Path(f'/proc/{pid}/cmdline')
        if command.exists() and str(Path(__file__)).encode() in command.read_bytes():
            os.kill(pid, signal.SIGTERM)
        pidfile.unlink(missing_ok=True)
    ROOT.with_suffix('.ready').unlink(missing_ok=True)


def main():
    """Start a loopback test server with a verifiable readiness signal and cleanup on exit."""
    if '--serve' in sys.argv:
        server = HTTPServer(('127.0.0.1', PORT), Capture)
        ROOT.with_suffix('.pid').write_text(str(os.getpid()))
        ROOT.with_suffix('.ready').write_text('synthetic-only')
        server.serve_forever()
    elif '--start' in sys.argv:
        stop()
        child = subprocess.Popen([sys.executable, __file__, '--serve'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(40):
            if ROOT.with_suffix('.ready').exists():
                print('SYNTHETIC_PROVIDER_READY')
                return
            if child.poll() is not None:
                break
            time.sleep(0.05)
        raise SystemExit('SYNTHETIC_PROVIDER_START_FAILED')
    elif '--stop' in sys.argv:
        stop()


if __name__ == '__main__':
    main()
