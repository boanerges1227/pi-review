"""Verify client address adaptation and private configuration permissions."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('client_config',Path(__file__).parents[1]/'scripts/rewrite-mcp-client.py')
mod=importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)

class ClientConfigTests(unittest.TestCase):
    def test_update_external_port_preserves_token_and_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'client.json'
            path.write_text(json.dumps({'url':'http://127.0.0.1:52785/mcp','token':'synthetic'}))
            mod.rewrite(path,52985)
            data=json.loads(path.read_text())
            self.assertEqual(data['url'],'http://127.0.0.1:52985/mcp')
            self.assertEqual(data['token'],'synthetic')
            self.assertEqual(path.stat().st_mode & 0o777,0o600)
            with self.assertRaises(ValueError): mod.rewrite(path,0)

if __name__=='__main__': unittest.main()
