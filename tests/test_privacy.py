from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('bsm_agent_test', ROOT / 'agent' / 'bsm_agent.py')
assert SPEC and SPEC.loader
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


class PrivacyTests(unittest.TestCase):
    def test_redacts_common_secrets(self) -> None:
        sample = (
            'Authorization: Bearer abcdefghijklmnopqrstuvwxyz\n'
            'api_key=' + 'sk-' + 'exampleExampleExample123456\n'
            'password: hello-world-secret\n'
            '-----BEGIN ' + 'PRIVATE KEY-----\nabc\n-----END ' + 'PRIVATE KEY-----\n'
        )
        clean = agent.redact_text(sample)
        self.assertNotIn('abcdefghijklmnopqrstuvwxyz', clean)
        self.assertNotIn('sk-example', clean)
        self.assertNotIn('hello-world-secret', clean)
        self.assertNotIn('BEGIN PRIVATE KEY', clean)

    def test_anonymizes_domain_email_and_public_ip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            config = pathlib.Path(td) / 'server.json'
            config.write_text(json.dumps({
                'domain': 'customer.example',
                'public_ip': '203.0.113.42',
            }))
            old = agent.CONFIG_FILE
            agent.CONFIG_FILE = config
            try:
                clean = agent.anonymize_text(
                    'admin@customer.example customer.example 203.0.113.42 8.8.8.8 127.0.0.1 10.0.0.1'
                )
            finally:
                agent.CONFIG_FILE = old
            self.assertNotIn('customer.example', clean)
            self.assertNotIn('203.0.113.42', clean)
            self.assertNotIn('8.8.8.8', clean)
            self.assertIn('127.0.0.1', clean)
            self.assertIn('10.0.0.1', clean)


if __name__ == '__main__':
    unittest.main()
