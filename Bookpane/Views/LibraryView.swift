import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: LibraryStore
    @State private var choosingFolder = false
    @State private var importingFrom: FolderLocation?
    @State private var selected: Book?
    @State private var removing: Book?
    @State private var details: Book?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 18) {
                        if library.books.isEmpty { emptyLibrary }
                        else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), alignment: .leading, spacing: 28) {
                                ForEach(library.recentBooks) { book in
                                    Button { selected = book } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            CoverView(book: book).aspectRatio(0.67, contentMode: .fit)
                                            Text(book.title).font(.system(.headline, design: .serif)).lineLimit(2)
                                            Text(book.author).font(.caption).foregroundStyle(BookpaneStyle.ink).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(book.title), by \(book.author)")
                                    .contextMenu {
                                        Button("Book details", systemImage: "info.circle") { details = book }
                                        Button("Remove book", systemImage: "trash", role: .destructive) { removing = book }
                                    }
                                }
                            }
                        }
                    }
                    importSection
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            .background(BookpaneStyle.paper)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                if library.isImporting {
                    HStack(spacing: 12) { ProgressView(); Text("Adding your book…").font(.subheadline) }
                        .padding().background(BookpaneStyle.paper, in: Capsule()).padding(.bottom, 24)
                        .accessibilityElement(children: .combine)
                }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): Task { await library.loadFolders(.choose(url)) }
                case .failure(let error):
                    let cocoaError = error as NSError
                    if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                        library.error = error.localizedDescription
                    }
                }
            }
            .sheet(item: $importingFrom) { location in
                EPUBPicker(location: location) { url in
                    importingFrom = nil
                    if let url { Task { _ = await library.importBook(url) } }
                }
            }
            .task { await library.loadFolders() }
            .navigationDestination(item: $selected) { book in ReaderView(book: book, library: library) }
            .alert("Unable to complete", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") { library.error = nil }
            } message: { Text(library.error ?? "") }
            .confirmationDialog("Remove this book and its reading progress?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove book", role: .destructive) { if let book = removing { library.remove(book) }; removing = nil }
                Button("Cancel", role: .cancel) { removing = nil }
            }
            .sheet(item: $details) { book in
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 16) {
                            CoverView(book: book).frame(width: 140, height: 210)
                            Text(book.title).font(.system(.title2, design: .serif)).multilineTextAlignment(.center)
                            Text(book.author).foregroundStyle(BookpaneStyle.ink)
                            Text("\(book.chapters.count) chapters · Stored on this iPhone").font(.footnote).foregroundStyle(BookpaneStyle.ink)
                        }.padding(32).frame(maxWidth: .infinity)
                    }
                    .background(BookpaneStyle.paper)
                    .toolbarBackground(BookpaneStyle.paper, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = nil } } }
                }.presentationDetents([.medium, .large])
            }
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import").font(.caption.weight(.semibold))
                Spacer()
                Button("Add folder", systemImage: "plus") { choosingFolder = true }
                    .labelStyle(.iconOnly)
            }
            ForEach(library.folders) { folder in
                HStack(spacing: 12) {
                    Button {
                        Task { importingFrom = await library.openFolder(folder) }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityHint("Choose an EPUB to import")
                    Button(role: .destructive) { library.removeFolder(folder) } label: {
                        Label("Remove folder", systemImage: "xmark.circle").labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Remove \(folder.name)")
                }
            }
            if library.folders.isEmpty {
                Text("Add a folder to import books.").font(.subheadline)
            }
        }
        .disabled(library.isLoadingFolder || library.isImporting)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(BookpaneStyle.ink)
            Text("Your next read\nstarts here.").font(.system(.largeTitle, design: .serif)).multilineTextAlignment(.center)
            Text("Add a folder below, then choose an EPUB to import.")
                .font(.subheadline).foregroundStyle(BookpaneStyle.ink).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 80)
    }

}
