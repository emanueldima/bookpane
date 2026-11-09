import WebKit

// Own the hidden WebKit work; callers receive chapter heights rather than browser details.
@MainActor
final class ChapterMeasurer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let rules: WKContentRuleList
    private var token = ""
    private var parsed = false
    private var failure: Error?
    private var expectedURL: URL?
    private static let timeout: Duration = .seconds(15)
    private static let pollDelay: Duration = .milliseconds(50)

    init(rules: WKContentRuleList) { self.rules = rules }

    func measure(book: Book, root: URL, host: WKWebView, viewport: CGSize,
                 render: (String) throws -> String) async throws -> [Double] {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.userContentController.add(self, contentWorld: .defaultClient, name: "progress")
        let view = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        view.navigationDelegate = self
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(view)
        defer {
            view.stopLoading()
            view.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "progress", contentWorld: .defaultClient)
            view.removeFromSuperview()
        }

        var heights: [Double] = []
        for chapter in book.chapters {
            try Task.checkCancellation()
            token = UUID().uuidString
            parsed = false
            failure = nil
            let controller = configuration.userContentController
            controller.removeAllUserScripts()
            // Eager images give unseen chapters their full height before counting.
            let script = try render(token) + "\nfor (const image of document.images) image.loading = 'eager';"
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: .defaultClient))
            let url = try BookPaths.resolve(chapter.path, relativeTo: root.appendingPathComponent(""), root: root)
            expectedURL = url
            view.loadFileURL(url, allowingReadAccessTo: root)
            heights.append(try await height(in: view))
        }
        return heights
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              body["token"] as? String == token else { return }
        if body["parsed"] as? Bool == true { parsed = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = EPUBError.invalid("Page measurement stopped.") }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Match the reader's rejection of redirects, frames, and external navigations.
        decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url?.isFileURL == true
                        && action.request.url?.standardizedFileURL.path == expectedURL?.standardizedFileURL.path
                        && action.navigationType == .other ? .allow : .cancel)
    }

    private func height(in view: WKWebView) async throws -> Double {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        var previous: Double?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let failure { throw failure }
            if parsed && !view.isLoading {
                let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                    view.evaluateJavaScript("""
                    (() => {
                      const height = document.documentElement.scrollHeight;
                      return document.fonts.status !== 'loading' && Array.from(document.images).every(image => image.complete)
                        ? height : null;
                    })()
                    """, in: nil, in: .defaultClient) { continuation.resume(with: $0) }
                }
                if let height = value as? Double, height.isFinite, height > 0 {
                    if previous == height { return height }
                    previous = height
                } else { previous = nil }
            }
            try await Task.sleep(for: Self.pollDelay)
        }
        throw EPUBError.invalid("Page measurement took too long.")
    }
}
