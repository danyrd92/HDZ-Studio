"""Offline regressions: no tracker, Telegram or user files are contacted."""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from relay_secure import Store, validate_torrent

def torrent(name=b'video.mkv', payload=b'fixture'):
    def s(value):
        return str(len(value)).encode() + b':' + value
    return b'd4:infod6:lengthi7e4:name' + s(name) + b'12:piece lengthi1048576e6:pieces20:' + hashlib.sha1(payload).digest() + b'ee'

class TransportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='hdz_test_transport_')
        self.addCleanup(self.directory.cleanup)
        self.store = Store(self.directory.name)

    def test_exact_torrent_survives_restart(self):
        data = torrent()
        ident = self.store.save_torrent('alice', 'exact.torrent', data)
        self.assertEqual(ident, hashlib.sha256(data).hexdigest())
        restored = Store(self.directory.name)
        self.assertEqual(restored.torrent('alice', ident), ('exact.torrent', data))
        self.assertIsNone(restored.torrent('bob', ident))
        self.assertIsNone(restored.torrent('alice', '1'))
        other = restored.save_torrent('alice', 'other.torrent', torrent(b'other.mkv'))
        self.assertNotEqual(ident, other)
        self.assertEqual(restored.torrent('alice', ident)[1], data)

    def test_command_retry_requires_ack(self):
        payload = {'requestId': 'same-request-123456', 'type': 'reset', 'session': 'session-a'}
        ident = self.store.command('alice', payload)
        self.assertEqual(ident, self.store.command('alice', payload))
        first = self.store.sync('alice', [])
        self.assertEqual(len(first), 1)
        self.assertEqual(first, self.store.sync('alice', []))
        self.assertEqual([], self.store.sync('bob', [{'id': ident, 'ok': True}]))
        self.assertEqual('pending', self.store.command_status('alice', ident)['status'])
        self.assertEqual([], self.store.sync('alice', [{'id': ident, 'ok': True}]))
        self.assertEqual('done', self.store.command_status('alice', ident)['status'])
        self.assertEqual(ident, self.store.command('alice', payload))
        self.assertEqual([], self.store.sync('alice', []))
        with self.assertRaises(ValueError):
            self.store.command('bob', payload)
        with self.assertRaises(ValueError):
            self.store.command('alice', dict(payload, type='other'))

    def test_expiry_and_bounded_queue(self):
        for n in range(100):
            self.store.command('alice', {'requestId': f'request-number-{n:04}', 'type': 'ping'})
        with self.assertRaises(ValueError):
            self.store.command('alice', {'requestId': 'request-overflow-101', 'type': 'ping'})
        with self.store.connect() as db:
            db.execute('UPDATE commands SET created=0')
        self.assertEqual([], self.store.sync('alice', []))
        self.assertEqual('failed', self.store.command_status('alice', 'request-number-0000')['status'])

    def test_reject_bad_torrent(self):
        for value in (b'', b'not a torrent', b'de', torrent()[:-1], torrent()+b'x', b'l'*34+b'e'*34):
            with self.subTest(value=value[:20]), self.assertRaises(ValueError):
                validate_torrent(value)
        self.assertEqual(validate_torrent(torrent())[b'info'][b'name'], b'video.mkv')

if __name__ == '__main__':
    unittest.main(verbosity=2)
