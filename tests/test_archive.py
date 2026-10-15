"""Black-box native service tests; fixtures are generated, never vendored."""
import json
import os
import pathlib
import struct
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ArchiveTests(unittest.TestCase):
    def run_zip(self, entries, mutate=None):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'book.zip'
            with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
                for name, data in entries:
                    z.writestr(name, data)
            if mutate:
                path.write_bytes(mutate(path.read_bytes()))
            return subprocess.run([os.environ.get('WIZ_TEST_ARCHIVE', str(ROOT / 'build/wiz-archive')), 'inspect', str(path)],
                                  capture_output=True, text=True)

    def test_inventory(self):
        result = self.run_zip([('目录/', ''), ('目录/text.txt', 'hello'), ('quote".txt', 'ok')])
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['totalBytes'], 7)
        self.assertEqual(data['entries'][1]['name'], '目录/text.txt')

    def test_bad_paths(self):
        for name in ['../x', '/x', 'a/../x', 'a\\x', 'C:/x', 'a//x', './x']:
            with self.subTest(name=name):
                result = self.run_zip([(name, 'x')])
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stderr)['ok'])
                self.assertEqual(result.stdout, '')

    def test_duplicates(self):
        self.assertNotEqual(self.run_zip([('x', 'a'), ('x', 'b')]).returncode, 0)

    def test_oversize(self):
        self.assertNotEqual(self.run_zip([('large', b'x' * (16 * 1024 * 1024 + 1))]).returncode, 0)

    def test_crc(self):
        def corrupt(data):
            central = data.index(b'PK\x01\x02')
            return data[:central + 16] + struct.pack('<I', 123) + data[central + 20:]
        self.assertNotEqual(self.run_zip([('x', 'contents')], corrupt).returncode, 0)

    def test_invalid_utf8(self):
        def corrupt_name(data):
            # Replace both local and central directory names with invalid UTF-8.
            return data.replace(b'name.txt', b'\xffame.txt')
        result = self.run_zip([('name.txt', 'hello')], corrupt_name)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertFalse(json.loads(result.stderr)['ok'])

    def test_embedded_nul(self):
        result = self.run_zip([('name.txt', 'hello')],
                              lambda data: data.replace(b'name.txt', b'na\x00e.txt'))
        self.assertNotEqual(result.returncode, 0)

    def test_payload_disguised_as_empty(self):
        def forge(data):
            data = bytearray(data)
            central = data.index(b'PK\x01\x02')
            # Forge matching headers, zero CRC and zero uncompressed length.
            for offset in [14, 22, central + 16, central + 24]:
                struct.pack_into('<I', data, offset, 0)
            return bytes(data)
        self.assertNotEqual(self.run_zip([('file', 'hidden payload' * 100)], forge).returncode, 0)

    def test_empty_files(self):
        result = self.run_zip([('empty', '')])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['totalBytes'], 0)

    def test_not_zip(self):
        result = self.run_zip([('x', 'a')], lambda _: b'not zip')
        self.assertNotEqual(result.returncode, 0)

    def test_many_files(self):
        self.assertNotEqual(self.run_zip([(str(i), '') for i in range(4097)]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
