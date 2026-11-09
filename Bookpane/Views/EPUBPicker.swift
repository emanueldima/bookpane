import SwiftUI
import UniformTypeIdentifiers

struct EPUBPicker: UIViewControllerRepresentable {
    private let location: FolderLocation
    private let choose: (URL?) -> Void

    init(location: FolderLocation, choose: @escaping (URL?) -> Void) {
        self.location = location
        self.choose = choose
    }

    func makeCoordinator() -> Coordinator { Coordinator(location: location, choose: choose) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.epub])
        picker.directoryURL = location.url
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let location: FolderLocation
        private let choose: (URL?) -> Void

        init(location: FolderLocation, choose: @escaping (URL?) -> Void) {
            self.location = location
            self.choose = choose
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            choose(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { choose(nil) }
    }
}
