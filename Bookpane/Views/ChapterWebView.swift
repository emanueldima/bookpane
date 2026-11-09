import SwiftUI
import WebKit

struct ChapterWebView: UIViewRepresentable {
    let model: ReaderModel
    private let contentInsets: EdgeInsets
    private let toggleControls: () -> Void

    init(model: ReaderModel, contentInsets: EdgeInsets = EdgeInsets(), toggleControls: @escaping () -> Void = {}) {
        self.model = model
        self.contentInsets = contentInsets
        self.toggleControls = toggleControls
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, toggleControls: toggleControls) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "progress")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = view
        model.flush = { [weak coordinator = context.coordinator] in coordinator?.flush() }
        // Block remote subresources as well as top-level navigations. Reading stays offline.
        let rule = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BookpaneOffline", encodedContentRuleList: rule) { [weak coordinator = context.coordinator, weak view] rules, error in
            guard let coordinator, let view else { return }
            if let rules {
                view.configuration.userContentController.add(rules)
                coordinator.preparePages(rules)
                coordinator.ready = true
                coordinator.loadIfNeeded(coordinator.model.target)
            } else {
                coordinator.finish(error?.localizedDescription ?? "Could not prepare the offline reader.")
            }
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let offset = view.scrollView.contentOffset
        let end = max(0, view.scrollView.contentSize.height - view.bounds.height)
        // Retain exposed margins when controls hide so UIKit cannot clamp the position.
        let insets = UIEdgeInsets(top: max(contentInsets.top, -offset.y), left: contentInsets.leading,
                                 bottom: max(contentInsets.bottom, offset.y - end), right: contentInsets.trailing)
        if view.scrollView.contentInset != insets {
            view.scrollView.contentInset = insets
            view.scrollView.verticalScrollIndicatorInsets = insets
            view.scrollView.setContentOffset(offset, animated: false)
        }

        // Read the target here so SwiftUI observes chapter changes.
        context.coordinator.loadIfNeeded(model.target)
        context.coordinator.applyIfNeeded(model.settings)
        context.coordinator.updatePages()
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.flush()
        coordinator.stopPageCount()
        coordinator.finish()
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "progress", contentWorld: .defaultClient)
        view.navigationDelegate = nil
        coordinator.model.flush = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: ReaderModel
        weak var webView: WKWebView?
        var ready = false
        private var loaded: UUID?
        private var navigation: WKNavigation?
        private var appliedSettings: ReaderSettings?
        private var loadTask: Task<Void, Never>?
        private var restoreTask: Task<Void, Never>?
        private var pageRules: WKContentRuleList?
        private var pageTask: Task<Void, Never>?
        private var pageLayout: PageLayout?
        private var viewport: CGSize?
        private var measuredHeights: [Double]?
        private var observedHeights: [Int: Double] = [:]
        private let toggleControls: () -> Void
        private static let loadTimeout: Duration = .seconds(15)
        private static let assetTimeout: Duration = .seconds(2)
        private static let assetPollDelay: Duration = .milliseconds(50)
        private static let pageDelay: Duration = .milliseconds(200)

        init(model: ReaderModel, toggleControls: @escaping () -> Void = {}) {
            self.model = model
            self.toggleControls = toggleControls
            super.init()
            watchLoad()
        }

        deinit {
            loadTask?.cancel()
            restoreTask?.cancel()
            pageTask?.cancel()
        }

        func preparePages(_ rules: WKContentRuleList) { pageRules = rules }

        func stopPageCount() {
            pageTask?.cancel()
            pageTask = nil
        }

        func updatePages() {
            guard !model.isLoading, let viewport, let webView, let pageRules else { return }
            let layout = PageLayout(viewport: viewport, settings: model.settings,
                                    appearance: webView.traitCollection.userInterfaceStyle)
            guard pageLayout != layout else { return }
            pageLayout = layout
            measuredHeights = nil
            observedHeights = [:]
            stopPageCount()
            model.beginPageCount()

            // Debounce layout changes and discard work from obsolete settings or orientations.
            pageTask = Task { [weak self, weak webView] in
                do {
                    try await Task.sleep(for: Self.pageDelay)
                    guard let self, let webView else { return }
                    let measurer = ChapterMeasurer(rules: pageRules)
                    var heights = try await measurer.measure(book: self.model.book, root: self.model.root,
                                                            host: webView, viewport: viewport) { token in
                        try self.script(token: token, fraction: 0, settings: layout.settings, fragment: "\"\"")
                    }
                    guard !Task.isCancelled, self.pageLayout == layout else { return }
                    for (index, height) in self.observedHeights { heights[index] = height }
                    self.measuredHeights = heights
                    self.model.receivePages(PageIndex(heights: heights, screenHeight: viewport.height))
                } catch {
                    guard !Task.isCancelled, let self, self.pageLayout == layout else { return }
                    self.model.failPageCount()
                }
            }
        }

        func loadIfNeeded(_ target: ReaderTarget) {
            guard ready, let webView, loaded != target.token else { return }
            restoreTask?.cancel()
            do {
                let url = try BookPaths.resolve(target.href, relativeTo: model.root.appendingPathComponent(""), root: model.root)
                let fragment = String(decoding: try JSONEncoder().encode(url.fragment?.removingPercentEncoding ?? url.fragment ?? ""), as: UTF8.self)
                let controller = webView.configuration.userContentController
                controller.removeAllUserScripts()
                controller.addUserScript(WKUserScript(source: try script(token: target.token.uuidString, fraction: target.fraction, settings: model.settings, fragment: fragment), injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
                loaded = target.token
                appliedSettings = model.settings
                model.error = nil
                model.isLoading = true
                watchLoad()
                // Fragment-only navigation skips script injection; reload to install the new token.
                if webView.url?.standardizedFileURL.path == url.standardizedFileURL.path {
                    navigation = webView.reload()
                } else {
                    navigation = webView.loadFileURL(url, allowingReadAccessTo: model.root)
                }
            } catch { finish(error.localizedDescription) }
        }

        func finish(_ error: String? = nil) {
            loadTask?.cancel()
            loadTask = nil
            restoreTask?.cancel()
            restoreTask = nil
            model.isLoading = false
            if let error { model.error = error }
        }

        func applyIfNeeded(_ settings: ReaderSettings) {
            guard ready, let webView, loaded == model.target.token, !model.isLoading,
                  appliedSettings != settings else { return }
            let token = model.target.token
            let script: String
            do { script = try settingsScript(settings, token: token.uuidString) }
            catch {
                model.error = "Could not prepare reading settings."
                return
            }
            appliedSettings = settings
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.model.target.token == token, self.appliedSettings == settings else { return }
                if case .failure = result {
                    self.model.error = "Could not change reading settings. Reopen the book to try again."
                }
            }
        }

        private func script(token: String, fraction: Double, settings: ReaderSettings, fragment: String) throws -> String {
            """
            (() => {
              const htmlNS = 'http://www.w3.org/1999/xhtml';
              const head = document.head || document.documentElement;
              let viewport = document.querySelector('meta[name="viewport"]');
              if (!viewport) {
                viewport = document.createElementNS(htmlNS, 'meta');
                viewport.setAttribute('name', 'viewport');
                head.append(viewport);
              }
              viewport.setAttribute('content', 'width=device-width, initial-scale=1, viewport-fit=cover');
              const style = document.createElementNS(htmlNS, 'style');
              style.textContent = `
                :root { color-scheme: light dark; --bookpane-paper: #fff; --bookpane-ink: #000; }
                html { background: var(--bookpane-paper); color: var(--bookpane-ink); }
                body { font-family: Georgia, serif; font-size: 19px; line-height: 1.65;
                       overflow-wrap: break-word; margin: 0; padding: 24px 0 48px; }
                img, svg, video { max-width: 100%; height: auto; }
                pre { white-space: pre-wrap; }
                @media (prefers-color-scheme: dark) { :root { --bookpane-paper: #000; --bookpane-ink: #fff; } }
              `;
              // A first stylesheet supplies defaults; publisher rules take precedence.
              head.prepend(style);
              // Justify prose even over inline rules; retain inherited heading alignment.
              const headingSelector = 'h1, h2, h3, h4, h5, h6';
              const headings = Array.from(document.querySelectorAll(headingSelector), element =>
                ({element, alignment: getComputedStyle(element).textAlign}));
              for (const element of document.querySelectorAll('body, body *')) {
                if (element.namespaceURI !== htmlNS || element.closest(headingSelector)) continue;
                element.style.setProperty('text-align', 'justify', 'important');
              }
              for (const {element, alignment} of headings) element.style.setProperty('text-align', alignment, 'important');
              // Save only color properties so restoring publisher colors keeps font scaling.
              const colorProperties = ['color', '-webkit-text-fill-color', 'background-color', 'border-color', 'text-decoration-color'];
              const publisherColors = Array.from(document.querySelectorAll('*'))
                .filter(element => element.namespaceURI === htmlNS)
                .map(element => ({element, styles: colorProperties.map(property =>
                  [property, element.style.getPropertyValue(property), element.style.getPropertyPriority(property)])}));
              window.bookpaneColors = (mode, token) => {
                if (token !== '\(token)') return;
                for (const {element, styles} of publisherColors) {
                  for (const [property, value, priority] of styles) {
                    if (mode === 'monochrome') {
                      const color = property === 'background-color'
                        ? (element === document.documentElement ? 'var(--bookpane-paper)' : 'transparent') : 'var(--bookpane-ink)';
                      element.style.setProperty(property, color, 'important');
                    } else if (value) {
                      element.style.setProperty(property, value, priority);
                    } else {
                      element.style.removeProperty(property);
                    }
                  }
                }
              };
              // Restore each publisher family independently; weight and italic styles stay intact.
              const publisherFonts = Array.from(document.querySelectorAll('*'))
                .filter(element => element.namespaceURI === htmlNS)
                .map(element => ({element, family: element.style.getPropertyValue('font-family'),
                  priority: element.style.getPropertyPriority('font-family')}));
              // Adjust text only, including absolute publisher sizes; images keep their dimensions.
              const scaleProperty = '--bookpane-text-scale';
              const scaleStyle = document.createElementNS(htmlNS, 'style');
              scaleStyle.textContent = `* { -webkit-text-size-adjust: var(${scaleProperty}) !important; }`;
              head.append(scaleStyle);
              document.documentElement.style.setProperty(scaleProperty, '\(settings.textScale)%');
              // Keep page spacing separate from colors so either override can be restored independently.
              const marginProperties = new Set([
                'margin-left', 'margin-right', 'margin-inline-start', 'margin-inline-end',
                'padding-left', 'padding-right', 'padding-inline-start', 'padding-inline-end',
                'width', 'min-width', 'max-width', 'inline-size', 'min-inline-size', 'max-inline-size', 'box-sizing'
              ]);
              const publisherMargins = [document.documentElement, document.body]
                .filter(element => element?.namespaceURI === htmlNS)
                .map(element => ({element, styles: Array.from(element.style)
                  .filter(property => marginProperties.has(property))
                  .map(property => [property, element.style.getPropertyValue(property), element.style.getPropertyPriority(property)])}));
              let restoring = true;
              function report() {
                if (restoring) return;
                const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
                window.webkit.messageHandlers.progress.postMessage({token: '\(token)', fraction: max ? scrollY / max : 0,
                  height: document.documentElement.scrollHeight, width: innerWidth, viewport: innerHeight,
                  settings: window.bookpaneLayout});
              }
              window.bookpaneReport = report;
              let timer;
              addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(report, 350); }, {passive: true});
              addEventListener('resize', report);
              addEventListener('load', report, true);
              document.fonts.addEventListener('loadingdone', report);
              const layoutObserver = new ResizeObserver(report);
              layoutObserver.observe(document.documentElement);
              if (document.body) layoutObserver.observe(document.body);
              window.bookpaneResize = (scale, token, marginMode, marginWidth, fontMode, fontFamily) => {
                if (token !== '\(token)') return;
                const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
                const fraction = max ? scrollY / max : 0;
                const wasRestoring = restoring;
                restoring = true;
                document.documentElement.style.setProperty(scaleProperty, `${scale}%`);
                for (const {element, family, priority} of publisherFonts) {
                  if (fontMode === 'custom') {
                    element.style.setProperty('font-family', `${JSON.stringify(fontFamily)}, serif`, 'important');
                  } else if (family) {
                    element.style.setProperty('font-family', family, priority);
                  } else {
                    element.style.removeProperty('font-family');
                  }
                }
                for (const {element, styles} of publisherMargins) {
                  for (const property of marginProperties) element.style.removeProperty(property);
                  if (marginMode === 'custom') {
                    const padding = element === document.body ? `${marginWidth}px` : '0px';
                    const overrides = {'margin-left':'0px', 'margin-right':'0px',
                      'padding-left':padding, 'padding-right':padding,
                      'width':'auto', 'min-width':'0px', 'max-width':'none', 'box-sizing':'border-box'};
                    for (const [property, value] of Object.entries(overrides)) {
                      element.style.setProperty(property, value, 'important');
                    }
                  } else {
                    for (const [property, value, priority] of styles) element.style.setProperty(property, value, priority);
                  }
                }
                // Keep the chapter fraction stable while fonts or side margins reflow text.
                if (!wasRestoring) {
                  scrollTo(0, fraction * Math.max(0, document.documentElement.scrollHeight - innerHeight));
                }
                restoring = wasRestoring;
                report();
              };
              \(try settingsScript(settings, token: token))
              window.bookpaneRestore = () => {
                // Reading scrollHeight forces layout without waiting for an animation frame.
                const fragment = \(fragment);
                if (fragment) {
                  document.getElementById(fragment)?.scrollIntoView();
                } else {
                  scrollTo(0, \(fraction) * Math.max(0, document.documentElement.scrollHeight - innerHeight));
                }
                restoring = false;
                window.webkit.messageHandlers.progress.postMessage({token: '\(token)', ready: true});
                report();
              };
              const gestures = {minimumSwipe: 60, dominance: 1.5, maximumTime: 600, edge: 24, tapDelay: 300};
              const interactive = 'a, button, input, textarea, select, summary, [contenteditable]';
              const selected = () => getSelection()?.isCollapsed === false;
              const sendAction = action => window.webkit.messageHandlers.progress.postMessage({token: '\(token)', action});
              let tapTimer;
              document.addEventListener('click', event => {
                clearTimeout(tapTimer);
                if (event.detail > 1 || selected() || event.target.closest?.(interactive)) return;
                if (event.clientX < innerWidth / 3 || event.clientX > innerWidth * 2 / 3) return;
                // Delay a single tap so double-tap selection can take precedence.
                tapTimer = setTimeout(() => { if (!selected()) sendAction('controls'); }, gestures.tapDelay);
              });
              document.addEventListener('selectionchange', () => { if (selected()) clearTimeout(tapTimer); });
              let touch;
              document.addEventListener('touchstart', event => {
                touch = undefined;
                if (event.touches.length !== 1 || selected() || event.target.closest?.(interactive)) return;
                const point = event.touches[0];
                if (point.clientX < gestures.edge || point.clientX > innerWidth - gestures.edge) return;
                touch = {x: point.clientX, y: point.clientY, time: Date.now()};
              }, {passive: true});
              document.addEventListener('touchmove', event => {
                if (event.touches.length !== 1) touch = undefined;
              }, {passive: true});
              document.addEventListener('touchcancel', () => { touch = undefined; }, {passive: true});
              document.addEventListener('touchend', event => {
                const start = touch;
                touch = undefined;
                if (!start || event.touches.length || event.changedTouches.length !== 1 || selected()) return;
                const point = event.changedTouches[0];
                const dx = point.clientX - start.x, dy = point.clientY - start.y;
                // Observe passively; vertical scrolling and native selection retain their gestures.
                if (Date.now() - start.time > gestures.maximumTime || Math.abs(dx) < gestures.minimumSwipe ||
                    Math.abs(dx) < Math.abs(dy) * gestures.dominance) return;
                clearTimeout(tapTimer);
                sendAction(dx < 0 ? 'next' : 'previous');
              }, {passive: true});
              // atDocumentEnd already guarantees parsed markup; full load can stall on SVG covers.
              window.webkit.messageHandlers.progress.postMessage({token: '\(token)', parsed: true});
            })();
            """
        }

        func flush() {
            webView?.evaluateJavaScript("window.bookpaneReport?.()", in: nil, in: .defaultClient) { _ in }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let token = body["token"] as? String, token == model.target.token.uuidString,
                  model.error == nil else { return }
            if let value = body["action"] as? String, let action = ReaderAction(rawValue: value) {
                guard !model.isLoading else { return }
                switch action {
                case .controls: toggleControls()
                case .next: model.move(1)
                case .previous: model.move(-1)
                }
                return
            }
            if body["parsed"] as? Bool == true, model.isLoading { restoreWhenReady() }
            if body["ready"] as? Bool == true, model.isLoading { finish(); model.save() }
            if let fraction = body["fraction"] as? Double { model.receiveProgress(fraction, token: token) }
            receiveLayout(body)
        }

        private func receiveLayout(_ body: [String: Any]) {
            guard !model.isLoading, let width = body["width"] as? Double,
                  let height = body["viewport"] as? Double, let contentHeight = body["height"] as? Double,
                  width.isFinite, height.isFinite, contentHeight.isFinite, width > 0, height > 0, contentHeight > 0,
                  let settings = body["settings"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: settings),
                  (try? JSONDecoder().decode(ReaderSettings.self, from: data)) == model.settings else { return }
            viewport = CGSize(width: width, height: height)
            updatePages()
            observedHeights[model.target.index] = contentHeight

            // Late image/font layout updates correct the cached count for the visible chapter.
            guard var heights = measuredHeights, heights[model.target.index] != contentHeight else { return }
            heights[model.target.index] = contentHeight
            measuredHeights = heights
            model.receivePages(PageIndex(heights: heights, screenHeight: height))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(navigation, error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(navigation, error) }
        private func failed(_ failedNavigation: WKNavigation?, _ error: Error) {
            guard failedNavigation === navigation, (error as NSError).code != NSURLErrorCancelled else { return }
            finish(error.localizedDescription)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish("The reader stopped unexpectedly. Reopen the book to continue.")
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                decisionHandler(.cancel)
                if url.isFileURL {
                    do {
                        let safe = try BookPaths.resolve(url.absoluteString, relativeTo: model.root, root: model.root)
                        model.open(BookPaths.relative(safe, root: model.root))
                    } catch { model.error = error.localizedDescription }
                } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                return
            }
            // Only allow our explicitly loaded main document. Reject book redirects and frames.
            guard action.targetFrame?.isMainFrame == true, url.isFileURL,
                  let expected = try? BookPaths.resolve(model.target.href, relativeTo: model.root.appendingPathComponent(""), root: model.root),
                  url.standardizedFileURL.path == expected.path else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }

        private func watchLoad() {
            loadTask?.cancel()
            let token = model.target.token
            // Native timing also covers a missing or failed readiness script.
            loadTask = Task { [weak self] in
                do { try await Task.sleep(for: Self.loadTimeout) }
                catch { return }
                guard let self, self.model.target.token == token, self.model.isLoading else { return }
                self.finish("Opening this chapter took too long. Reopen the book to try again.")
                self.webView?.stopLoading()
            }
        }

        private func restoreWhenReady() {
            guard let webView, restoreTask == nil else { return }
            let token = model.target.token
            // Native timing avoids stalled page events and script promise callbacks.
            restoreTask = Task { [weak self, weak webView] in
                guard let self, let webView else { return }
                let deadline = ContinuousClock.now.advanced(by: Self.assetTimeout)
                while !Task.isCancelled, ContinuousClock.now < deadline {
                    if await self.assetsReady(webView) { break }
                    do { try await Task.sleep(for: Self.assetPollDelay) }
                    catch { return }
                }
                guard !Task.isCancelled, self.model.target.token == token, self.model.isLoading else { return }
                webView.evaluateJavaScript("window.bookpaneRestore()", in: nil, in: .defaultClient) { [weak self] result in
                    guard let self, self.model.target.token == token else { return }
                    if case .failure = result {
                        self.finish("Could not restore this chapter. Reopen the book to try again.")
                    }
                }
            }
        }

        private func assetsReady(_ webView: WKWebView) async -> Bool {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript("document.fonts.status !== 'loading' && Array.from(document.images).every(img => img.complete || img.loading === 'lazy')", in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? Bool ?? false)
                    case .failure: continuation.resume(returning: false)
                    }
                }
            }
        }

        private enum ReaderAction: String {
            case controls, next, previous
        }

        private func settingsScript(_ settings: ReaderSettings, token: String) throws -> String {
            let family = String(decoding: try JSONEncoder().encode(settings.fontFamily), as: UTF8.self)
            let layout = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            return """
            window.bookpaneLayout = \(layout);
            window.bookpaneResize(\(settings.textScale), '\(token)', '\(settings.marginMode.rawValue)', \(settings.sideMargin), '\(settings.fontMode.rawValue)', \(family));
            window.bookpaneColors('\(settings.colorMode.rawValue)', '\(token)');
            """
        }

        private struct PageLayout: Equatable {
            let viewport: CGSize
            let settings: ReaderSettings
            let appearance: UIUserInterfaceStyle
        }
    }
}
