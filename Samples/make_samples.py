"""Create original, redistributable EPUB 2/3 smoke-test books (no dependencies)."""
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED, ZIP_DEFLATED
from xml.sax.saxutils import escape

ROOT = Path(__file__).parent
chapters = [
 ('A quiet beginning', 'There is a particular pleasure in opening a book with no hurry to finish it. This little volume is here to make sure your reader feels at home.', 'beginnings'),
 ('Room to wander', 'A chapter is a small invitation. Follow a thought, pause at a sentence, and let the page keep your place while you look away.', 'wandering'),
 ('A place to return', 'Close the book and open it again. The words should be waiting where you left them. That is the promise of a simple reader.', 'returning'),
]
for version in [2, 3]:
    with ZipFile(ROOT/f'A Quiet Beginning - EPUB {version}.epub', 'w') as z:
        z.writestr('mimetype', 'application/epub+zip', compress_type=ZIP_STORED)
        def write(path, text): z.writestr(path, text, compress_type=ZIP_DEFLATED)
        write('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        nav_item = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' if version == 3 else '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        modified = '<meta property="dcterms:modified">2026-11-04T00:00:00Z</meta>' if version == 3 else ''
        items = ''.join(f'<item id="c{i}" href="text/chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1,4))
        spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(1,4))
        write('EPUB/package.opf', f'''<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="{version}.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:bookpane:quiet-beginning-{version}</dc:identifier><dc:title>A Quiet Beginning</dc:title><dc:creator>Bookpane Studio</dc:creator><dc:language>en</dc:language>{modified}</metadata><manifest>{nav_item}{items}<item id="css" href="style.css" media-type="text/css"/></manifest><spine{' toc="ncx"' if version == 2 else ''}>{spine}</spine></package>''')
        write('EPUB/style.css', 'h1 { font-weight: normal; margin: 1.5em 0; } p { margin: 0 0 1em; } a { color: inherit; }')
        links = ''.join(f'<li><a href="text/chapter{i}.xhtml">{escape(title)}</a></li>' for i,(title,_,_) in enumerate(chapters,1))
        if version == 3:
            write('EPUB/nav.xhtml', f'''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol>{links}</ol></nav></body></html>''')
        else:
            points = ''.join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>{escape(title)}</text></navLabel><content src="text/chapter{i}.xhtml"/></navPoint>' for i,(title,_,_) in enumerate(chapters,1))
            write('EPUB/toc.ncx', f'''<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="urn:bookpane:quiet-beginning-2"/><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head><docTitle><text>A Quiet Beginning</text></docTitle><navMap>{points}</navMap></ncx>''')
        for i,(title,text,anchor) in enumerate(chapters,1):
            paragraphs = ''.join(f'<p>{escape(text)}</p>' for _ in range(18))
            write(f'EPUB/text/chapter{i}.xhtml', f'''<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="en"><head><title>{escape(title)}</title><link rel="stylesheet" href="../style.css"/></head><body><h1>{escape(title)}</h1>{paragraphs}<h2 id="{anchor}">A little further</h2><p>Try leaving and returning to this chapter to check your saved position.</p><p><a href="chapter{(i%3)+1}.xhtml">Visit the next chapter</a></p></body></html>''')
print('Created EPUB 2 and EPUB 3 samples.')
