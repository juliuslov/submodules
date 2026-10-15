"""Independent PDB/MOBI fixture generator; no production serializer imports."""
import struct


def make_mobi(raw=None, compression=1, encoding=65001, title='Fixture book', author='A reader', language='en', encoded=None):
    codec = 'utf-8' if encoding == 65001 else 'cp1252'
    if raw is None:
        raw = '<html><body><h1>Opening</h1><p>Hello &amp; safe.</p></body></html>'.encode(codec)
    count = (len(raw) + 4095) // 4096
    def exth(tag, value):
        data = value.encode(codec)
        return struct.pack('>II', tag, 8 + len(data)) + data
    entries = exth(100, author) + exth(503, title) + exth(524, language)
    meta = struct.pack('>4sII', b'EXTH', (12 + len(entries) + 3) // 4 * 4, 3) + entries
    meta += b'\0' * (-len(meta) % 4)
    name = title.encode(codec)
    record0 = bytearray(248 + len(meta) + (len(name) + 5) // 4 * 4)
    struct.pack_into('>HHIHHHH', record0, 0, compression, 0, len(raw), count, 4096, 0, 0)
    struct.pack_into('>4sIIIII', record0, 16, b'MOBI', 232, 2, encoding, 42, 6)
    for offset in list(range(40, 80, 4)) + [108, 112, 120, 164, 168, 200, 208, 224, 244]:
        struct.pack_into('>I', record0, offset, 0xffffffff)
    struct.pack_into('>III', record0, 80, count + 1, 248 + len(meta), len(name))
    struct.pack_into('>I', record0, 92, 9)
    struct.pack_into('>I', record0, 104, 6)
    struct.pack_into('>I', record0, 128, 0x40)
    struct.pack_into('>HH', record0, 192, 1, count)
    record0[248:248+len(meta)] = meta
    record0[248+len(meta):248+len(meta)+len(name)] = name
    records = [bytes(record0)]
    for offset in range(0, len(raw), 4096):
        chunk = raw[offset:offset+4096]
        if encoded is not None:
            assert count == 1
            chunk = encoded
        elif compression == 2:
            chunk = b''.join(bytes([len(chunk[i:i+8])]) + chunk[i:i+8] for i in range(0, len(chunk), 8))
        records.append(chunk)
    records.append(b'\xe9\x8e\r\n')
    pdb = bytearray(78 + len(records) * 8 + 2)
    pdb[:7] = b'fixture'
    pdb[60:68] = b'BOOKMOBI'
    struct.pack_into('>H', pdb, 76, len(records))
    offset = len(pdb)
    for i, record in enumerate(records):
        struct.pack_into('>II', pdb, 78+i*8, offset, i*2)
        offset += len(record)
    return bytes(pdb) + b''.join(records)


def make_hybrid():
    """Legacy/KF8 header fixture with a real BOUNDARY record."""
    base = make_mobi()
    count, = struct.unpack_from('>H', base, 76)
    offsets = [struct.unpack_from('>I', base, 78+i*8)[0] for i in range(count)] + [len(base)]
    records = [base[offsets[i]:offsets[i+1]] for i in range(count)]
    old0 = records[0]
    record0 = bytearray(old0[:260] + struct.pack('>III', 121, 12, 4) + old0[260:])
    struct.pack_into('>I', record0, 84, struct.unpack_from('>I', old0, 84)[0] + 12)
    struct.pack_into('>I', record0, 252, struct.unpack_from('>I', old0, 252)[0] + 12)
    struct.pack_into('>I', record0, 256, 4)
    kf8 = bytearray(old0[:248] + b'\0'*32 + old0[248:])
    for offset, value in [(20, 264), (36, 8), (104, 8), (84, struct.unpack_from('>I', old0, 84)[0]+32)]:
        struct.pack_into('>I', kf8, offset, value)
    parts = [record0, records[1], records[2], b'BOUNDARY', kf8, records[1], records[2]]
    header = bytearray(78 + len(parts)*8 + 2)
    header[:6] = b'hybrid'
    header[60:68] = b'BOOKMOBI'
    struct.pack_into('>H', header, 76, len(parts))
    offset = len(header)
    for i, record in enumerate(parts):
        struct.pack_into('>II', header, 78+i*8, offset, i*2)
        offset += len(record)
    return bytes(header) + b''.join(parts)
