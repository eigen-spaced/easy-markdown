import AppKit

let app = NSApplication.shared

// Headless mode used by `easymd --pdf`: EasyMarkdown --export-pdf <input.md> <output.pdf>
let args = CommandLine.arguments
if let flag = args.firstIndex(of: "--export-pdf"), args.count > flag + 2 {
    // Relative paths must be made absolute, or the preview's base URL won't resolve.
    let input = URL(fileURLWithPath: args[flag + 1]).absoluteURL.standardizedFileURL
    let output = URL(fileURLWithPath: args[flag + 2]).absoluteURL.standardizedFileURL
    guard let data = try? Data(contentsOf: input), let markdown = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("easymd: cannot read \(input.path)\n".utf8))
        exit(1)
    }
    app.setActivationPolicy(.prohibited)
    PDFExporter.export(markdown: markdown, baseDirectory: input.deletingLastPathComponent(), to: output) { ok in
        if !ok { FileHandle.standardError.write(Data("easymd: PDF export failed\n".utf8)) }
        exit(ok ? 0 : 1)
    }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
