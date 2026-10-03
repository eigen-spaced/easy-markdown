import AppKit
import WebKit

/// Renders markdown in an offscreen web view and prints it to a paginated PDF.
///
/// A dedicated web view is used so export works regardless of the window's view mode,
/// and so the page width matches the paper's printable width (no scaling).
final class PDFExporter: NSObject {
    private static var active: Set<PDFExporter> = []

    private let preview = MarkdownPreview()
    private let window: NSWindow
    private let printInfo: NSPrintInfo
    private let completion: (Bool) -> Void
    private var didPrint = false

    private init(output: URL, completion: @escaping (Bool) -> Void) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.topMargin = 48
        info.bottomMargin = 48
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        printInfo = info
        self.completion = completion

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: info.paperSize.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // PDFs always use the light variant of the current preview theme.
        window.appearance = NSAppearance(named: .aqua)
        super.init()
        preview.webView.frame = window.contentView!.bounds
        window.contentView = preview.webView
    }

    static func export(markdown: String, baseDirectory: URL, to output: URL,
                       completion: @escaping (Bool) -> Void) {
        let exporter = PDFExporter(output: output, completion: completion)
        active.insert(exporter)
        exporter.preview.load(baseDirectory: baseDirectory)
        exporter.preview.render(markdown) { [weak exporter] in
            // One more runloop turn so layout settles before printing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exporter?.print() }
        }
        // Fail rather than wait forever if the page never finishes rendering.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak exporter] in
            guard let exporter, !exporter.didPrint else { return }
            active.remove(exporter)
            completion(false)
        }
    }

    private func print() {
        didPrint = true
        let op = preview.webView.printOperation(with: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = preview.webView.bounds
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // The window was never ordered on screen; releasing it is enough.
        Self.active.remove(self)
        completion(success)
    }
}
