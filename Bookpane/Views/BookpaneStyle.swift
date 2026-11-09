import SwiftUI

enum BookpaneStyle {
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? .black : .white })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? .white : .black })
}

struct ThemeStyle: ViewModifier {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func body(content: Content) -> some View {
        let scheme: ColorScheme?
        switch settings.theme {
        case .system: scheme = nil
        case .dark: scheme = .dark
        case .light: scheme = .light
        }
        return content.environment(settings).preferredColorScheme(scheme)
    }
}

struct CoverView: View {
    let book: Book
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = coverImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    BookpaneStyle.ink
                    VStack(spacing: 12) {
                        Image(systemName: "leaf").font(.title2)
                        Text(book.title).font(.system(.title3, design: .serif)).multilineTextAlignment(.center).lineLimit(4)
                        Rectangle().frame(width: 28, height: 1)
                        Text(book.author).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                    }.foregroundStyle(BookpaneStyle.paper).padding(16)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
    private var coverImage: UIImage? {
        guard let path = book.coverPath,
              let url = try? BookPaths.resolve(path, relativeTo: BookPaths.content(book.id).appendingPathComponent(""), root: BookPaths.content(book.id)) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
