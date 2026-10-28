#!/usr/bin/env python3
"""Update the private local client address for the Compose port mapping without exposing or changing the token."""
import json
import os
from pathlib import Path
import sys
import tempfile


def rewrite(path, port):
    """Validate the port and atomically replace client configuration using a private temporary file."""
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError('INVALID_PORT')
    path=Path(path)
    data=json.loads(path.read_text())
    if not isinstance(data, dict) or not isinstance(data.get('token'),str) or not data['token']:
        raise ValueError('INVALID_CLIENT')
    data['url']=f'http://127.0.0.1:{port}/mcp'
    fd, name=tempfile.mkstemp(prefix='.mcp-client-',dir=path.parent)
    try:
        os.fchmod(fd,0o600)
        with os.fdopen(fd,'w') as output:
            json.dump(data,output,separators=(',',':'))
            output.flush();os.fsync(output.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)


if __name__=='__main__':
    try:
        if len(sys.argv)!=3: raise ValueError('INVALID_ARGUMENT')
        rewrite(sys.argv[1],int(sys.argv[2]))
    except (ValueError,OSError,json.JSONDecodeError):
        print('CLIENT_CONFIG_FAILED',file=sys.stderr);sys.exit(1)
