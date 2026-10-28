#!/usr/bin/env python3
"""Verify publisher MCP authentication and the read-only tool catalog without exposing credentials."""
import json
from pathlib import Path
import sys


def valid_catalog(response):
    """Require all three read-only tools so an unauthorized empty catalog cannot pass."""
    try:
        tools=response['result']['tools']
        return len(tools)==3 and {item['name'] for item in tools} == {
            'mcp_identity_review_case', 'mcp_identity_review_evidence', 'mcp_identity_review_run_trace'}
    except (KeyError,TypeError):
        return False


def valid_transport(response):
    """When client credentials are revoked, verify MCP initialization transport only, not authenticated tool access."""
    try:
        return bool(response['result']['protocolVersion'])
    except (KeyError,TypeError):
        return False


def main():
    """Read the private client configuration and perform initialization and tool discovery."""
    from mcp_client import Client
    client=Client(json.loads(Path('artifacts/mcp-client.json').read_text()))
    initial=client.initialize()
    if sys.argv[1:] == ['--transport-only']:
        if not valid_transport(initial): raise ValueError('PUBLISH_GATEWAY_NOT_READY')
        print('PUBLISH_TRANSPORT_READY')
        return
    if sys.argv[1:] or not valid_transport(initial) or not valid_catalog(client.rpc('tools/list')):
        raise ValueError('PUBLISH_GATEWAY_NOT_READY')
    print('PUBLISH_GATEWAY_READY')


if __name__=='__main__':
    try: main()
    except Exception:
        print('PUBLISH_GATEWAY_NOT_READY',file=sys.stderr);sys.exit(1)
