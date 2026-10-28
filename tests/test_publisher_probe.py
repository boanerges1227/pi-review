"""Verify that the publisher readiness probe discovers all readonly tools."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('publisher_probe',Path(__file__).parents[1]/'scripts/check-mcp-publisher.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PublisherProbeTests(unittest.TestCase):
    def test_requires_expected_authenticated_catalog(self):
        valid={'result':{'tools':[{'name':'mcp_identity_review_case'},{'name':'mcp_identity_review_evidence'},{'name':'mcp_identity_review_run_trace'}]}}
        self.assertTrue(module.valid_catalog(valid))
        self.assertFalse(module.valid_catalog({'result':{'tools':[]}}))
        self.assertFalse(module.valid_catalog({'httpStatus':401}))

    def test_transport_probe_requires_mcp_initialize(self):
        self.assertTrue(module.valid_transport({'result':{'protocolVersion':'2025-06-18'}}))
        self.assertFalse(module.valid_transport({'httpStatus':401}))
        self.assertFalse(module.valid_transport({'result':{}}))

if __name__=='__main__': unittest.main()
