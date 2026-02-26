import SwiftUI
import WebKit
import BlackSwanEditCore

@MainActor
struct MermaidPreviewSheet: View {
    @ObservedObject var documentStore = DocumentStore.shared
    @State private var html: String = ""
    @State private var statusText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Mermaid Preview")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button("Refresh") { rebuildHTML() }
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
            }
            .padding(10)
            Divider()

            if html.isEmpty {
                Text("No Mermaid diagram found in the active document.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MermaidWebView(html: html)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { rebuildHTML() }
        .onChange(of: documentStore.activeDocument?.id) { _ in rebuildHTML() }
    }

    private func rebuildHTML() {
        guard let doc = documentStore.activeDocument else {
            html = ""
            statusText = "No active document"
            return
        }

        let bytes = doc.buffer.bytes(in: 0..<doc.buffer.byteLength)
        let text = String(data: bytes, encoding: .utf8) ?? ""

        let ext = doc.fileURL?.pathExtension.lowercased()
        let source: String?

        if ext == "mmd" || ext == "mermaid" {
            source = text
        } else {
            source = extractFirstMermaidBlock(fromMarkdown: text)
        }

        guard let src = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !src.isEmpty
        else {
            html = ""
            statusText = "No mermaid block"
            return
        }

        statusText = doc.fileURL?.lastPathComponent ?? "Untitled"
        html = mermaidHTML(for: src)
    }

    private func extractFirstMermaidBlock(fromMarkdown md: String) -> String? {
        // MVP: first fenced block: ```mermaid ... ```
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var inBlock = false
        var buf: [Substring] = []

        for line in lines {
            if !inBlock {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "```mermaid" {
                    inBlock = true
                    buf.removeAll(keepingCapacity: true)
                }
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                return buf.joined(separator: "\n")
            }
            buf.append(line)
        }

        return nil
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func loadBundledWebJS(_ filename: String) -> String? {
        let ns = filename as NSString
        let name = ns.deletingPathExtension
        let ext = ns.pathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Web") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func sanitizeForScriptTag(_ js: String) -> String {
        js.replacingOccurrences(of: "</script>", with: "<\\/script>")
    }

    private func mermaidHTML(for source: String) -> String {
        let escaped = escapeHTML(source)
        let mermaidJS = sanitizeForScriptTag(loadBundledWebJS("mermaid.min.js") ?? "")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body { margin: 0; padding: 16px; font: 13px -apple-system, system-ui, sans-serif; background: #fff; }
            .err { color: #b00020; white-space: pre-wrap; }
          </style>
          <script>\(mermaidJS)</script>
        </head>
        <body>
          <div class="mermaid">\(escaped)</div>
          <script>
            if (window.mermaid) {
              mermaid.initialize({ startOnLoad: true, theme: 'default' });
            } else {
              document.body.innerHTML = '<div class="err">Missing bundled mermaid.min.js</div>';
            }
          </script>
        </body>
        </html>
        """
    }
}

struct MermaidWebView: NSViewRepresentable {
    var html: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: cfg)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
