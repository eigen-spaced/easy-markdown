import AppKit
import UniformTypeIdentifiers
import WebKit

/// Serves `easymd://` URLs: `/__easymd__/*` from the app bundle, the preview shell, and
/// everything else straight from disk so relative image paths in a document just work.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "easymd"
    static let shellName = "__easymd_preview__.html"
    private static let assetPrefix = "/__easymd__/"

    static var webResourcesURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    }

    /// The shell page is addressed as if it lived in the document's directory so that
    /// relative links and images resolve against that directory.
    static func shellURL(in directory: URL) -> URL {
        var components = URLComponents(url: directory.absoluteURL.appendingPathComponent(shellName), resolvingAgainstBaseURL: false)!
        components.scheme = scheme
        components.host = nil
        return components.url!
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path

        let fileURL: URL
        if path.hasPrefix(Self.assetPrefix) {
            fileURL = Self.webResourcesURL.appendingPathComponent(String(path.dropFirst(Self.assetPrefix.count)))
        } else if url.lastPathComponent == Self.shellName {
            fileURL = Self.webResourcesURL.appendingPathComponent("preview.html")
        } else {
            fileURL = URL(fileURLWithPath: path)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// Colours the preview theme uses, reported from CSS so the editor can match.
struct ThemeColors {
    var background, foreground, muted, link, heading, code, accent: NSColor

    init?(_ dict: [String: String]) {
        guard let bg = NSColor(hex: dict["bg"]), let fg = NSColor(hex: dict["fg"]) else { return nil }
        background = bg
        foreground = fg
        muted = NSColor(hex: dict["muted"]) ?? fg
        link = NSColor(hex: dict["link"]) ?? fg
        heading = NSColor(hex: dict["heading"]) ?? fg
        code = NSColor(hex: dict["code"]) ?? fg
        accent = NSColor(hex: dict["accent"]) ?? fg
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// A WKWebView that renders markdown via the bundled markdown-it shell.
final class MarkdownPreview: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    /// Called when the user clicks a link to another markdown file.
    var onOpenMarkdown: ((URL) -> Void)?
    /// Called when the user scrolls the preview; the value is the fractional source line at
    /// the top of the view, or -1 for "scrolled to the end".
    var onScroll: ((Double) -> Void)?
    /// Called when the preview theme (or light/dark appearance) changes.
    var onThemeColors: ((ThemeColors) -> Void)?

    private static let messages = ["ready", "scroll", "theme"]
    private var isReady = false
    private var scrollInFlight = false
    private var pendingScrollLine: Double?
    private var pending: (String, (() -> Void)?)?
    private var shellURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: LocalSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        let handler = WeakMessageHandler(self)
        Self.messages.forEach { config.userContentController.add(handler, name: $0) }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    deinit {
        Self.messages.forEach { webView.configuration.userContentController.removeScriptMessageHandler(forName: $0) }
    }

    /// Loads the shell page rooted at `directory`. Must be called before `render`.
    func load(baseDirectory directory: URL) {
        let url = LocalSchemeHandler.shellURL(in: directory)
        guard url != shellURL else { return }
        shellURL = url
        isReady = false
        scrollInFlight = false
        pendingScrollLine = nil
        webView.load(URLRequest(url: url))
    }

    /// Renders `markdown`; `completion` fires once the DOM, images and diagrams are ready.
    func render(_ markdown: String, completion: (() -> Void)? = nil) {
        guard isReady else {
            pending = (markdown, completion)
            return
        }
        webView.callAsyncJavaScript("return await window.easymd.render(src)",
                                    arguments: ["src": markdown], in: nil, in: .page) { result in
            if case .failure(let error) = result { NSLog("EasyMarkdown render failed: \(error)") }
            completion?()
        }
    }

    /// Scrolls so the given (fractional, 0-based) source line is at the top; -1 means the end.
    func scroll(toLine line: Double) {
        guard isReady else { return }
        // Scroll events can arrive several times per frame; keep at most one call in flight and
        // send only the latest position once it returns.
        if scrollInFlight {
            pendingScrollLine = line
            return
        }
        scrollInFlight = true
        webView.callAsyncJavaScript("window.easymd.scrollToLine(line)", arguments: ["line": line],
                                    in: nil, in: .page) { [weak self] _ in
            guard let self else { return }
            self.scrollInFlight = false
            if let next = self.pendingScrollLine {
                self.pendingScrollLine = nil
                self.scroll(toLine: next)
            }
        }
    }

    @objc private func settingsChanged() {
        applyTheme()
    }

    private func applyTheme() {
        guard isReady else { return }
        let settings = Settings.shared
        webView.callAsyncJavaScript("window.easymd.setTheme(preview, code)",
                                    arguments: ["preview": settings.previewTheme, "code": settings.codeTheme],
                                    in: nil, in: .page, completionHandler: nil)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "ready":
            isReady = true
            applyTheme()
            if let (markdown, completion) = pending {
                pending = nil
                render(markdown, completion: completion)
            }
        case "scroll":
            if let line = message.body as? Double { onScroll?(line) }
        case "theme":
            if let dict = message.body as? [String: String], let colors = ThemeColors(dict) { onThemeColors?(colors) }
        default:
            break
        }
    }
    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }

        // In-page anchors (#heading) resolve against the shell URL.
        if url.scheme == LocalSchemeHandler.scheme, url.path == shellURL?.path {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)

        if url.scheme == LocalSchemeHandler.scheme {
            let file = URL(fileURLWithPath: url.path)
            if ["md", "markdown", "mdown", "mkd"].contains(file.pathExtension.lowercased()) {
                onOpenMarkdown?(file)
            } else if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.open(file)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
