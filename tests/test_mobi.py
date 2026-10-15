import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from mobi_fixture import make_mobi

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / 'services/mobi/python/decode.py'


class MobiTests(unittest.TestCase):
    def invoke(self, data, command='inspect', worker=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture with spaces.mobi'
            path.write_bytes(data)
            argv = ['python3', '-B', str(WORKER), str(path)] if worker else [
                os.environ.get('WIZ_TEST_MOBI', str(ROOT / 'build/wiz-mobi')), command, str(path)]
            return subprocess.run(argv, capture_output=True, timeout=30)

    def test_native_inspect(self):
        result = self.invoke(make_mobi())
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['version'], 6)
        self.assertEqual(data['title'], 'Fixture book')
        self.assertEqual(data['author'], 'A reader')

    def test_native_palmdoc(self):
        raw = '<html><body><p>Xin chào 你好 &amp; safe.</p></body></html>'.encode()
        result = self.invoke(make_mobi(raw, compression=2), command='text')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, raw)

    def test_kindleunpack_palmdoc(self):
        result = self.invoke(make_mobi(compression=2), worker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['data']['book']['chapters'][0]['text'], 'Hello & safe.')

    def test_windows1252(self):
        raw = '<html><body><h1>Café</h1><p>Crème brûlée.</p></body></html>'.encode('cp1252')
        result = self.invoke(make_mobi(raw, encoding=1252, title='Café'), worker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        book = json.loads(result.stdout)['data']['book']
        self.assertEqual(book['title'], 'Café')
        self.assertEqual(book['chapters'][0]['text'], 'Crème brûlée.')

    def test_invalid_tables(self):
        for data in [b'not mobi', make_mobi()[:90]]:
            self.assertNotEqual(self.invoke(data).returncode, 0)
        for offset, value, fmt in [(78, 1, '>I'), (86, 1, '>I'), (76, 65535, '>H')]:
            data = bytearray(make_mobi())
            struct.pack_into(fmt, data, offset, value)
            result = self.invoke(data)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(json.loads(result.stderr)['ok'])
            self.assertEqual(result.stdout, b'')

    def test_unsupported_and_encrypted(self):
        for field, value, fmt in [(12, 2, '>H'), (36, 8, '>I'), (0, 17480, '>H'),
                                  (4, 9*1024*1024, '>I'), (10, 4097, '>H'), (40, 1, '>I')]:
            data = bytearray(make_mobi())
            first, = struct.unpack_from('>I', data, 78)
            struct.pack_into(fmt, data, first+field, value)
            self.assertNotEqual(self.invoke(data).returncode, 0)

    def test_declared_length_mismatch(self):
        data = bytearray(make_mobi())
        first, = struct.unpack_from('>I', data, 78)
        struct.pack_into('>I', data, first+4, 1)
        self.assertNotEqual(self.invoke(data).returncode, 0)

    def test_markup_not_executed_and_chapters_preserved(self):
        raw = b'<html><head><title>Hidden</title></head><body><script>bad()</script><style>bad</style><h1>One</h1><p>Safe &lt;text&gt;.</p><mbp:pagebreak/><h1>Two</h1><p>Next.</p></body></html>'
        result = self.invoke(make_mobi(raw), worker=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        chapters = json.loads(result.stdout)['data']['book']['chapters']
        self.assertEqual(chapters, [{'title': 'One', 'text': 'Safe <text>.'}, {'title': 'Two', 'text': 'Next.'}])

    def test_reject_xml_declarations(self):
        raw = b'<!DOCTYPE html [<!ENTITY x SYSTEM "file:///etc/passwd">]><html><body><p>&x;</p></body></html>'
        self.assertNotEqual(self.invoke(make_mobi(raw), worker=True).returncode, 0)

    def test_large_chapter_split_does_not_cut_unicode(self):
        spec = importlib.util.spec_from_file_location('mobi_worker', WORKER)
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        parser = worker.TextBook()
        text = '你好' * 200000
        parser.feed('<h1>Long</h1><p>' + text + '</p>')
        parser.finish_chapter()
        self.assertEqual(len(parser.chapters), 2)
        self.assertEqual(''.join(chapter['text'] for chapter in parser.chapters), text)
        self.assertTrue(all(len(chapter['text'].encode()) <= 1024*1024 for chapter in parser.chapters))

    def test_native_oversized_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'large.mobi'
            with path.open('wb') as stream:
                stream.truncate(64*1024*1024+1)
            result = subprocess.run([str(ROOT / 'build/wiz-mobi'), 'inspect', str(path)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
