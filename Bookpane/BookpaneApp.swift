import SwiftUI

@main
struct BookpaneApp: App {
    @State private var library = LibraryStore()
    @State private var settings = AppSettings()
    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .modifier(ThemeStyle(settings: settings))
                .foregroundStyle(BookpaneStyle.ink)
                .tint(BookpaneStyle.ink)
        }
    }
}
