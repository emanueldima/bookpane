# Bookpane

A small native iPhone EPUB reader. iOS 17+, SwiftUI, WebKit, Foundation, Observation, CryptoKit, and ZIPFoundation. No backend or accounts. Mostly vibe-coded.

## Open and run

1. On a Mac with Xcode 15 or later, open `Bookpane.xcodeproj`.
2. Select the **Bookpane** scheme and an iPhone simulator. Press **Run**.
3. For a physical iPhone, select your development team under Signing & Capabilities and change `com.example.Bookpane` to your own bundle identifier.
4. Add EPUBs to a folder in the simulator's Files app. Under Import, tap **+** to save that folder. Tap its name to open the system EPUB picker; selecting a file adds it to the Library without opening it. The `Samples` folder includes original EPUB 2 and EPUB 3 books for testing.

Xcode resolves the pinned ZIPFoundation 0.9.20 Swift package (MIT; no tracking or collected data declared). Its license is bundled in `Bookpane/ThirdPartyNotices.txt`. Optional Python scripts regenerate the sample books, ZIP test fixtures, and checked-in Xcode project.

## Included

- Library with a three-column cover grid directly below the status bar, no title or import toolbar, and generated cover placeholders, ordered by last access (import date for unopened books).
- Files import, local copies, duplicate detection by archive SHA-256, and confirmed removal.
- Import section below the books with a small heading and **+** to add local or cloud folders. Saved folder buttons open the system EPUB picker at that folder, including system previews. Selected books are added to the Library without opening; duplicate archives reuse the existing copy. Folder bookmarks persist between launches, the previous single folder migrates automatically, and removing a folder preserves its files and imported books. No file listing, counting, refresh, or background scanning.
- EPUB 2 OPF/NCX and EPUB 3 package/navigation parsing.
- Vertically scrolling XHTML chapters with justified body text, publisher heading alignment, images, and fonts.
- Full-height reading behind the Dynamic Island; controls overlay the page without moving text, with room to scroll clear of both toolbars. Tap the center to toggle controls. Swipe left/right for next/previous chapters, or use chapter buttons and contents.
- Chapter loading indicator appears only after 500 ms; failures still report errors.
- Reading position stored as chapter ID and scroll fraction; restore waits for fonts and images.
- Whole-book screen-based page numbers in the bottom bar, alongside the chapter title. Counts update for font, margin, and orientation changes; partial chapter screens count as pages. Reading stays available while chapters are measured.
- Per-book font size with Aa controls, live 80–250% text scaling, saved preferences, and Reset.
- Publisher fonts by default; a saved per-book override selects any installed font family, initially Georgia. The selector appears while enabled; disabling restores publisher fonts and remembers the selection. Bold and italic styling is preserved.
- Publisher colors by default; a saved per-book override applies pure black/white without changing artwork.
- Publisher side margins by default; a saved per-book override starts at 0 px and adjusts both sides live from 0–48 px in 4 px steps.
- App-wide System/Dark/Light theme in Reading settings, saved between launches and applied to the Library and reader; System is the default. Accessible control labels and native text selection.
- Atomic JSON persistence in Application Support. No absolute sandbox paths stored.

## Boundaries

Simulator tests cover EPUB parsing, ZIP extraction, folder imports, and reader behavior. Physical-device and cloud-provider behavior still need manual verification.

Supported: unencrypted reflowable EPUB 2/3 with XHTML spine documents and UTF-8 archive filenames, including ZIP64 archives supported by ZIPFoundation. Files that declare `META-INF/encryption.xml` are rejected, including font obfuscation. Fixed-layout books, DRM, split archives, and non-spine linked documents are not supported. Duplicate detection identifies identical archive bytes, not equivalent editions. Resume is approximate after layout changes; page numbers describe the current screen layout rather than a print edition. There are no EPUB CFIs, annotations, or search yet.

ZIPFoundation handles ZIP structure and stored/DEFLATE decoding. `ZIPExtractor` checks CRCs and actual output sizes, rejects traversal paths, links, and conflicting filenames, and limits imports to 128 MiB compressed, 32 MiB per resource, 256 MiB total output, and 10,000 entries. Extraction occurs in a fresh staging directory that is removed on failure. Resources can only resolve inside their own book directory. Book JavaScript is disabled; an isolated app script handles appearance and progress. HTTP(S) subresources are blocked, and user-activated external links open through iOS.

Known ZIPFoundation 0.9.20 limitation: archive comments containing an embedded ZIP end-record signature may cause valid books to be rejected. A fixture test records this as an expected failure.

## Files

```text
Bookpane/
  Core/          EPUB/ZIP import, models, storage, reader state
  Views/         Library, reader, contents, and WKWebView bridge
Tests/
  EPUBParserTests.swift   iOS-hosted parser/path tests
  FolderAccessTests.swift Saved folders, migration, picker, and import tests
  ZIPExtractorTests.swift ZIP limits, paths, corruption, and format fixtures
  Fixtures/ZIP/           Independent archives generated with Python zipfile
Samples/                  Two original EPUB smoke-test books
```

## Verification

On a Mac, select **Product → Test** to run the XCTest target, or use an installed simulator name:

```sh
xcodebuild -project Bookpane.xcodeproj -scheme Bookpane \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

Regenerate the ZIP fixtures with Python 3:

```sh
python3 Tests/make_zip_fixtures.py
```

Manual acceptance checks:

1. Import both samples. Confirm title, author, ordered chapters, and contents.
2. Scroll halfway through a chapter, return to Library, and reopen. Repeat after terminating and relaunching the app.
3. Follow chapter links and TOC entries. Check previous/next boundaries.
4. Import the same file twice through a saved folder. Confirm there is one imported copy and the reader stays closed.
5. Switch light/dark mode, rotate, and test a book with embedded images/fonts. Check VoiceOver controls and large system text.
6. Cancel an import, import a damaged file, and remove a book. Confirm useful errors and persistent library state.
7. Under Import, add multiple local or iCloud Drive folders with **+**. Tap each folder and check the system EPUB picker starts there. Cancel without changes, then choose a book; confirm it appears in the Library without opening. Relaunch to verify saved folders and migration from the previous single-folder setting. Adding the same folder twice should not duplicate it. Remove one folder; confirm the others, source files, and imported books remain. Unavailable folders should report an error when tapped and remain removable.
8. Open Aa while reading. Change font size and try Reset. Confirm resizing keeps your approximate position, the size survives relaunch, and another book keeps its own size.
9. Open a book: controls and status bar start hidden; text scrolls to both screen edges, behind the Dynamic Island. Tap the center twice to show/hide controls; confirm text stays fixed. With controls visible, scroll to the beginning/end and confirm text clears both toolbars. Swipe left/right through chapters and check both boundaries. Confirm vertical scrolling, links, and text selection still work. Use Show controls with VoiceOver.
10. Open Reading settings. Toggle Override publisher colors; confirm changes apply immediately without moving the reading position. Turn it off to restore publisher colors. Reopen the book to verify persistence; check another book remains unchanged and font Reset preserves the color choice.
11. Toggle Override publisher margins. Confirm the slider starts at 0 px and adjusts both sides in 4 px steps through 48 px. Turn it off to restore publisher spacing. Reopen the book and switch chapters to verify persistence; another book and font Reset should leave the preference unchanged.
12. In Reading settings, switch Theme between System, Dark, and Light. Confirm the Library and reader follow the choice, it survives relaunch, and System follows the phone's appearance. Publisher color overrides remain independent. Check three books fit per Library row.
13. Enable Override publisher fonts. Choose an installed font; confirm it applies immediately, preserves bold/italic styling and approximate reading position, and survives reopening and chapter changes. Disable to restore publisher fonts; reenable to recover the choice. Another book and font-size Reset should leave it unchanged.
14. Show reader controls and wait for “Calculating pages…” to become “Page X of Y.” Check numbering across chapters and at the book's end. Change fonts, margins, and orientation; confirm counts update and reading remains available. Showing/hiding controls should preserve numbering.

The sample text is original to this project and may be freely reused. Their repeated paragraphs intentionally make chapters long enough to test scrolling and resume.
