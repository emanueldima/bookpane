"""Generate independent ZIP fixtures for ZIPExtractorTests with Python's zipfile."""
from pathlib import Path
import io
import stat
import struct
import warnings
import zipfile
from unittest import mock

ROOT = Path(__file__).resolve().parent / 'Fixtures' / 'ZIP'
LOCAL_HEADER_SIZE = 30
LOCAL_SIZE_OFFSET = 22
CENTRAL_SIZE_OFFSET = 24
CENTRAL_SIGNATURE = b'PK\x01\x02'
MIMETYPE = b'application/epub+zip'
MIB = 1024 * 1024


def archive(entries, method=zipfile.ZIP_DEFLATED, mimetype=MIMETYPE):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=method) as book:
        if mimetype is not None:
            book.writestr(zipfile.ZipInfo('mimetype'), mimetype)
        for name, data in entries:
            info = zipfile.ZipInfo(name) if isinstance(name, str) else name
            info.compress_type = method
            book.writestr(info, data)
    return output.getvalue()


def resize(data, size):
    result = bytearray(data)
    with zipfile.ZipFile(io.BytesIO(data)) as book:
        offset = book.getinfo('chapter.xhtml').header_offset
    central = result.index(CENTRAL_SIGNATURE, result.index(CENTRAL_SIGNATURE) + 1)
    struct.pack_into('<I', result, offset + LOCAL_SIZE_OFFSET, size)
    struct.pack_into('<I', result, central + CENTRAL_SIZE_OFFSET, size)
    return result


def write_fixtures():
    ROOT.mkdir(parents=True, exist_ok=True)
    entries = [('text/chapter.xhtml', b'<p>Hello</p>' * 1000), ('empty', b'')]
    fixtures = {
        'stored': archive(entries, zipfile.ZIP_STORED),
        'deflated': archive(entries),
        'missing-mimetype': archive(entries, mimetype=None),
        'wrong-mimetype': archive(entries, mimetype=b'text/plain'),
        'empty-archive': archive([], mimetype=None),
        'directories': archive([('text/', b''), ('text/chapter.xhtml', b'Chapter')]),
        'literal-path': archive([('a%20chapter.xhtml', b'Literal'), ('caf\u00e9.xhtml', b'Unicode')]),
    }
    for index, path in enumerate(['../escape', '/absolute', 'safe/../../escape', 'a\\b',
                                  'C:/file', 'a/./file', 'a//file', 'a/\x01file']):
        fixtures[f'unsafe-{index}'] = archive([(path, b'bad')])
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        for name, paths in [('duplicate', ['chapter', 'chapter']), ('case-collision', ['Chapter', 'chapter']),
                            ('unicode-collision', ['caf\u00e9', 'cafe\u0301']), ('type-collision', ['text/', 'text'])]:
            fixtures[name] = archive([(path, b'') for path in paths])

    link = zipfile.ZipInfo('link')
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    fixtures['symlink'] = archive([(link, b'/outside')])

    stored = bytearray(archive([('chapter.xhtml', b'hello')], zipfile.ZIP_STORED))
    with zipfile.ZipFile(io.BytesIO(stored)) as book:
        offset = book.getinfo('chapter.xhtml').header_offset
    stored[offset + LOCAL_HEADER_SIZE + len('chapter.xhtml')] ^= 1
    fixtures['damaged-crc'] = stored
    small = archive([('chapter.xhtml', b'hello')])
    fixtures['oversized-entry'] = resize(small, 33 * MIB)
    fixtures['overreported-size'] = resize(small, 100)
    fixtures['underreported-size'] = resize(archive([('chapter.xhtml', b'x' * 100_000)]), 1)
    for index, length in enumerate([0, 1, 21, 30, len(small) - 1, len(small) - 22]):
        fixtures[f'truncated-{index}'] = small[:length]

    total = bytearray(archive([(f'entry-{index}', b'') for index in range(9)]))
    central = total.index(CENTRAL_SIGNATURE)
    for _ in range(9):
        central = total.index(CENTRAL_SIGNATURE, central + 1)
        struct.pack_into('<I', total, central + CENTRAL_SIZE_OFFSET, 32 * MIB)
    fixtures['oversized-total'] = total
    fixtures['too-many-entries'] = archive([(f'entry-{index}', b'') for index in range(10_000)])

    class NonSeekable(io.BytesIO):
        def seekable(self): return False
        def seek(self, *args): raise io.UnsupportedOperation()

    output = NonSeekable()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as book:
        book.writestr(zipfile.ZipInfo('mimetype'), MIMETYPE)
        info = zipfile.ZipInfo('chapter.xhtml')
        info.compress_type = zipfile.ZIP_DEFLATED
        book.writestr(info, b'Descriptor')
    fixtures['descriptors'] = output.getvalue()
    output = io.BytesIO()
    # Force ZIP64 sizes, offsets, and end records without a multi-gigabyte fixture.
    with mock.patch.object(zipfile, 'ZIP64_LIMIT', 1), zipfile.ZipFile(output, 'w') as book:
        book.writestr(zipfile.ZipInfo('mimetype'), MIMETYPE)
        info = zipfile.ZipInfo('chapter.xhtml')
        info.compress_type = zipfile.ZIP_DEFLATED
        with book.open(info, 'w', force_zip64=True) as chapter:
            chapter.write(b'ZIP64')
        book.comment = b'Bookpane fixture'
    fixtures['zip64-comment'] = output.getvalue()
    output = io.BytesIO(archive([('chapter.xhtml', b'Comment')]))
    with zipfile.ZipFile(output, 'a') as book:
        book.comment = b'comment PK\x05\x06 not the real directory'
    fixtures['embedded-signature-comment'] = output.getvalue()

    for name, data in fixtures.items():
        (ROOT / (name + '.epub')).write_bytes(data)
    print(f'Generated {len(fixtures)} ZIP fixtures.')


if __name__ == '__main__':
    write_fixtures()
