"""Flask in-memory client with synthetic keys and a disposable private store."""
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from test_transport import torrent

fixture = tempfile.TemporaryDirectory(prefix='hdz_test_api_')
os.environ.update(HDZ_BOT_TOKEN='test-bot-no-network', HDZ_CHAT_ID='test-chat',
                  HDZ_SHARED_KEY='test-owner-key-123456789', HDZ_PANEL_KEY='test-panel-key-123456789',
                  HDZ_AGENT_KEYS=json.dumps({'other': 'test-other-key-123456789'}),
                  HDZ_STATE_DIR=fixture.name, HDZ_UPDATE_DIR=fixture.name)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import relay

class ApiTests(unittest.TestCase):
    def setUp(self):
        self.client = relay.app.test_client()
        self.pc = {'X-HDZ-Key': os.environ['HDZ_SHARED_KEY']}
        self.panel = {'X-HDZ-Panel': os.environ['HDZ_PANEL_KEY']}
        self.client.post('/agent/sync', json={'protocol': 2, 'session': 'test-session', 'uiTs': 123}, headers=self.pc)

    def test_auth_and_private_updates(self):
        for path in ('/api/state', '/api/torrent', '/api/cmd/status'):
            self.assertEqual(self.client.get(path).status_code, 403)
        self.assertEqual(self.client.post('/agent/sync', json={}).status_code, 403)
        Path(fixture.name, 'soporte.cfg').write_text('private-test-data')
        Path(fixture.name, 'version.json').write_text(json.dumps({'archivos': ['soporte.cfg', '../outside', 'HDZ-Core.ps1']}))
        Path(fixture.name, 'HDZ-Core.ps1').write_text('# fixture')
        self.assertEqual(self.client.get('/update/soporte.cfg').status_code, 404)
        self.assertEqual(self.client.get('/update/../outside').status_code, 404)
        self.assertEqual(self.client.get('/update/HDZ-Core.ps1').status_code, 200)

    def test_ack_and_session(self):
        data = {'type': 'ping', 'requestId': 'test-api-request-001', 'session': 'test-session'}
        queued = self.client.post('/api/cmd', json=data, headers=self.panel)
        self.assertEqual(queued.status_code, 200)
        ident = queued.json['id']
        for _ in range(2):
            sync = self.client.post('/agent/sync', json={'protocol': 2, 'session': 'test-session', 'uiTs': 124}, headers=self.pc)
            self.assertEqual(sync.json['cmds'][0]['_id'], ident)
        done = self.client.post('/agent/sync', json={'protocol': 2, 'session': 'test-session', 'uiTs': 125, '_acks': [{'id': ident, 'ok': True}]}, headers=self.pc)
        self.assertEqual(done.json['cmds'], [])
        self.assertEqual(self.client.get('/api/cmd/status?id='+ident, headers=self.panel).json['status'], 'done')
        self.assertEqual(self.client.post('/api/cmd', json=dict(data, session='old'), headers=self.panel).status_code, 409)
        self.assertEqual(self.client.post('/api/cmd', json=[], headers=self.panel).status_code, 400)
        self.assertEqual(self.client.get('/api/cmd/status?agent=other&id='+ident, headers=self.panel).status_code, 404)

    def test_exact_download(self):
        data = torrent()
        result = self.client.post('/agent/torrent', data={'torrent': (io.BytesIO(data), 'tracker.torrent')}, headers=self.pc)
        self.assertEqual(result.status_code, 200)
        ident = result.json['id']
        downloaded = self.client.get('/api/torrent?id='+ident, headers=self.panel)
        self.assertEqual(downloaded.data, data)
        self.assertIn('no-store', downloaded.headers['Cache-Control'])
        self.assertEqual(self.client.get('/api/torrent?agent=other&id='+ident, headers=self.panel).status_code, 404)
        self.assertEqual(self.client.get('/api/torrent?id=1', headers=self.panel).status_code, 404)
        invalid = self.client.post('/agent/torrent', data={'torrent': (io.BytesIO(b'bad'), 'bad.torrent')}, headers=self.pc)
        self.assertEqual(invalid.status_code, 400)

    def test_stale_ui_not_connected(self):
        relay._states['owner']['ui_changed'] = 0
        result = self.client.get('/api/state', headers=self.panel)
        self.assertTrue(result.json['online'])
        self.assertFalse(result.json['responsive'])
        self.assertEqual(self.client.post('/api/cmd', json={'type':'ping','session':'test-session'}, headers=self.panel).status_code, 409)

if __name__ == '__main__':
    try:
        unittest.main(verbosity=2)
    finally:
        fixture.cleanup()
