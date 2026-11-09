import SwiftUI

struct ReaderView: View {
    @State private var model: ReaderModel
    @State private var showingContents = false
    @State private var showingFontSize = false
    @State private var showingFontPicker = false
    @State private var showingControls = false
    @State private var loadingToken: UUID?
    @State private var controlsHeight: CGFloat = 0
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.scenePhase) private var scenePhase
    private static let loadingDelay: Duration = .milliseconds(500)

    init(book: Book, library: LibraryStore) {
        _model = State(initialValue: ReaderModel(book: book, library: library))
    }

    var body: some View {
        GeometryReader { geometry in
            ChapterWebView(model: model, contentInsets: showingControls
                ? EdgeInsets(top: geometry.safeAreaInsets.top, leading: 0, bottom: geometry.safeAreaInsets.bottom + controlsHeight, trailing: 0)
                : EdgeInsets()) { showingControls.toggle() }
                .ignoresSafeArea(.container, edges: .vertical)
                .background(BookpaneStyle.paper.ignoresSafeArea())
                .accessibilityAction(named: Text(showingControls ? "Hide controls" : "Show controls")) { showingControls.toggle() }
                .overlay {
                    // Keep an escape available before the chapter's gesture script loads.
                    if model.isLoading || model.error != nil {
                        Color.clear.contentShape(Rectangle()).onTapGesture { showingControls.toggle() }
                    }
                }
                .overlay { if model.isLoading && loadingToken == model.target.token { ProgressView("Opening chapter…").padding().background(BookpaneStyle.paper, in: RoundedRectangle(cornerRadius: 12)) } }
                // Delay feedback per chapter to avoid flashes during quick loads.
                .task(id: model.isLoading ? model.target.token : nil) {
                    loadingToken = nil
                    guard model.isLoading else { return }
                    let token = model.target.token

                    do { try await Task.sleep(for: Self.loadingDelay) }
                    catch { return }

                    guard !Task.isCancelled, model.isLoading, model.target.token == token else { return }
                    loadingToken = token
                }
        }
            .toolbarBackground(BookpaneStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle(model.book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showingControls ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!showingControls)
            .persistentSystemOverlays(showingControls ? .automatic : .hidden)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Reading settings", systemImage: "textformat.size") { showingFontSize = true }
                        .disabled(model.isLoading)
                    Button("Table of contents", systemImage: "list.bullet") { showingContents = true }
                }
            }
            .overlay(alignment: .bottom) {
                if showingControls {
                    HStack(spacing: 8) {
                        Button { model.move(-1) } label: { Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly).frame(width: 48, height: 44) }
                            .disabled(model.target.index == 0)
                        Spacer()
                        VStack(spacing: 3) {
                            Text(model.chapter.title).font(.caption).lineLimit(1)
                            Text(pageLabel).font(.caption2).monospacedDigit().foregroundStyle(BookpaneStyle.ink)
                        }.accessibilityElement(children: .combine)
                        Spacer()
                        Button { model.move(1) } label: { Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly).frame(width: 48, height: 44) }
                            .disabled(model.target.index == model.book.chapters.count - 1)
                    }.padding(.horizontal, 12).padding(.vertical, 6).background(BookpaneStyle.paper)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in controlsHeight = height }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingContents) {
                NavigationStack {
                    List {
                        entries(model.book.contents, depth: 0)
                            .listRowBackground(BookpaneStyle.paper)
                            .listRowSeparatorTint(BookpaneStyle.ink)
                    }
                        .scrollContentBackground(.hidden)
                        .background(BookpaneStyle.paper)
                        .toolbarBackground(BookpaneStyle.paper, for: .navigationBar)
                        .toolbarBackground(.visible, for: .navigationBar)
                        .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingContents = false } } }
                }.presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingFontSize) { fontSettings }
            .alert("Reader error", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .onChange(of: scenePhase) { _, phase in if phase != .active { model.flush?(); model.save() } }
            .onDisappear { model.flush?(); model.save() }
    }

    private var pageLabel: String {
        if let current = model.pageNumber, let total = model.pageTotal { return "Page \(current) of \(total)" }
        return model.pageState == .unavailable ? "Pages unavailable" : "Calculating pages…"
    }

    private var fontSettings: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme")
                        Picker("Theme", selection: Binding(get: { appSettings.theme }, set: { appSettings.changeTheme($0) })) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.rawValue.capitalized).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Applies across the app.").font(.footnote)
                    }
                    HStack(spacing: 24) {
                        Button("A−") { model.changeFontSize(.decrease) }
                            .accessibilityLabel("Decrease font size")
                            .disabled(!model.settings.canDecrease || model.isLoading)
                        Text("\(model.settings.textScale)%").monospacedDigit()
                            .accessibilityLabel("Font size")
                            .accessibilityValue("\(model.settings.textScale) percent")
                        Button("A+") { model.changeFontSize(.increase) }
                            .accessibilityLabel("Increase font size")
                            .disabled(!model.settings.canIncrease || model.isLoading)
                    }
                    .font(.title2)
                    .buttonStyle(.plain)
                    Button("Reset") { model.changeFontSize(.reset) }
                        .disabled(model.settings.textScale == ReaderSettings.standard.textScale || model.isLoading)
                    Toggle("Override publisher fonts", isOn: Binding(
                        get: { model.settings.fontMode == .custom },
                        set: { model.changeFont($0 ? .custom : .publisher, family: model.settings.fontFamily) }
                    ))
                    .disabled(model.isLoading)
                    if model.settings.fontMode == .custom {
                        Button { showingFontPicker = true } label: {
                            HStack {
                                Text("Font")
                                Spacer()
                                Text(model.settings.fontFamily).font(.custom(model.settings.fontFamily, size: 17))
                                Image(systemName: "chevron.right")
                            }
                        }
                        .disabled(model.isLoading)
                    }
                    Toggle("Override publisher colors", isOn: Binding(
                        get: { model.settings.colorMode == .monochrome },
                        set: { model.changeColors($0 ? .monochrome : .publisher) }
                    ))
                    .disabled(model.isLoading)
                    Toggle("Override publisher margins", isOn: Binding(
                        get: { model.settings.marginMode == .custom },
                        set: { model.changeMargins($0 ? .custom : .publisher, width: model.settings.sideMargin) }
                    ))
                    .disabled(model.isLoading)
                    VStack(spacing: 8) {
                        HStack {
                            Text("Side margins")
                            Spacer()
                            Text("\(model.settings.sideMargin) px").monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(model.settings.sideMargin) },
                            set: { model.changeMargins(.custom, width: Int($0)) }
                        ), in: Double(ReaderSettings.marginRange.lowerBound)...Double(ReaderSettings.marginRange.upperBound), step: Double(ReaderSettings.marginStep))
                        .accessibilityLabel("Side margins")
                        .accessibilityValue("\(model.settings.sideMargin) pixels")
                    }
                    .disabled(model.settings.marginMode == .publisher || model.isLoading)
                    Text("Applies to this book.").font(.footnote).foregroundStyle(BookpaneStyle.ink)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BookpaneStyle.paper)
            .toolbarBackground(BookpaneStyle.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Reading settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingFontSize = false } } }
            .sheet(isPresented: $showingFontPicker) {
                FontPicker(family: model.settings.fontFamily) { family in
                    if let family { model.changeFont(.custom, family: family) }
                    showingFontPicker = false
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // Flattening keeps deeply nested publisher navigation out of SwiftUI's recursive view type system.
    private func entries(_ contents: [ContentsEntry], depth: Int) -> some View {
        ForEach(Array(rows(contents, depth: depth).enumerated()), id: \.offset) { _, row in
            Button {
                model.open(row.entry.href)
                showingContents = false
            } label: {
                HStack {
                    Text(row.entry.title).foregroundStyle(BookpaneStyle.ink)
                    Spacer()
                    if row.entry.href.components(separatedBy: "#")[0] == model.chapter.path {
                        Image(systemName: "checkmark").accessibilityLabel("Current chapter")
                    }
                }.padding(.leading, CGFloat(min(row.depth, 6)) * 16).padding(.vertical, 6)
            }
        }
    }
    private func rows(_ entries: [ContentsEntry], depth: Int) -> [(entry: ContentsEntry, depth: Int)] {
        entries.flatMap { [(entry: $0, depth: depth)] + rows($0.children, depth: depth + 1) }
    }
}

// The system picker also grants access to fonts installed by the user.
private struct FontPicker: UIViewControllerRepresentable {
    private let family: String
    private let choose: (String?) -> Void

    init(family: String, choose: @escaping (String?) -> Void) {
        self.family = family
        self.choose = choose
    }

    func makeCoordinator() -> Coordinator { Coordinator(choose: choose) }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.selectedFontDescriptor = UIFontDescriptor(fontAttributes: [.family: family])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        private let choose: (String?) -> Void

        init(choose: @escaping (String?) -> Void) { self.choose = choose }

        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            guard let descriptor = picker.selectedFontDescriptor else { return }
            choose(UIFont(descriptor: descriptor, size: 0).familyName)
        }

        func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) { choose(nil) }
    }
}
