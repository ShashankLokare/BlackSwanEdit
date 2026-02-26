import SwiftUI
import WebKit
import BlackSwanEditCore

@MainActor
struct JSXPreviewSheet: View {
    @ObservedObject var documentStore = DocumentStore.shared
    @State private var html: String = ""
    @State private var statusText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("JSX Preview (Offline)")
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
                Text("No JSX source found in the active document.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JSXWebView(html: html)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
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

        if ext == "jsx" {
            source = text
        } else {
            source = extractFirstJSXBlock(fromMarkdown: text)
        }

        guard let src = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !src.isEmpty
        else {
            html = ""
            statusText = "No JSX block"
            return
        }

        statusText = doc.fileURL?.lastPathComponent ?? "Untitled"

        // If this is a real .jsx file on disk, we can load local relative imports fully offline.
        if ext == "jsx", let url = doc.fileURL {
            do {
                let bundle = try LocalJSXBundler().bundle(entry: url)
                html = jsxHTML(bundle: bundle)
                return
            } catch {
                html = jsxHTML(errorText: "Bundling failed: \(error.localizedDescription)")
                return
            }
        }

        // For inline markdown snippets, treat it as a single file.
        html = jsxHTML(bundle: .singleFile(source: src))
    }

    private func extractFirstJSXBlock(fromMarkdown md: String) -> String? {
        // MVP: first fenced block: ```jsx ... ```
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false)
        var inBlock = false
        var buf: [Substring] = []

        for line in lines {
            if !inBlock {
                let tag = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if tag == "```jsx" || tag == "```javascript jsx" {
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

    private func escapeForJSStringLiteral(_ s: String) -> String {
        // For embedding in a JS template string literal.
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
    }

    private func escapeForJSON(_ s: String) -> String {
        // Build JSON safely by going through JSONSerialization.
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           let json = String(data: data, encoding: .utf8) {
            // Strip the surrounding [ ... ]
            return String(json.dropFirst().dropLast())
        }
        return "\"\""
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
        // Prevent accidental </script> termination.
        js.replacingOccurrences(of: "</script>", with: "<\\/script>")
    }

    private func jsxHTML(errorText: String) -> String {
        let err = escapeForJSON(errorText)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { margin: 0; padding: 16px; font: 13px -apple-system, system-ui, sans-serif; background: #ffffff; }
          .err { color: #b00020; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
        </style>
        </head>
        <body><div class="err">\(err)</div></body></html>
        """
    }

    private func jsxHTML(bundle: LocalJSXBundle) -> String {
        let entryJSON = escapeForJSON(bundle.entryModuleID)

        // Encode module map as JSON: { "id": "source", ... }
        var dictObj: [String: String] = [:]
        for (k, v) in bundle.modules {
            dictObj[k] = v
        }
        let modulesJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: dictObj, options: []),
           let json = String(data: data, encoding: .utf8) {
            modulesJSON = json
        } else {
            modulesJSON = "{}"
        }

        let reactJS = sanitizeForScriptTag(loadBundledWebJS("react.production.min.js") ?? "")
        let reactDOMJS = sanitizeForScriptTag(loadBundledWebJS("react-dom.production.min.js") ?? "")
        let babelJS = sanitizeForScriptTag(loadBundledWebJS("babel.min.js") ?? "")
        if reactJS.isEmpty || reactDOMJS.isEmpty || babelJS.isEmpty {
            return jsxHTML(errorText: "Missing bundled JS runtime files under Resources/Web (react/react-dom/babel).")
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            body { margin: 0; font: 13px -apple-system, system-ui, sans-serif; background: #ffffff; }
            .bar { padding: 10px 12px; border-bottom: 1px solid #e5e5e5; background: #fafafa; color: #333; }
            .wrap { display: grid; grid-template-columns: 1fr 360px; height: calc(100vh - 42px); }
            #root { padding: 14px; overflow: auto; }
            #log { padding: 14px; overflow: auto; border-left: 1px solid #e5e5e5; background: #fcfcfc; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; white-space: pre-wrap; }
            .err { color: #b00020; }
            .hint { color: #555; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          </style>
          <script>\(reactJS)</script>
          <script>\(reactDOMJS)</script>
          <script>\(babelJS)</script>
        </head>
        <body>
          <div class="bar">Offline JSX Preview. Entry should export <code>App</code> or <code>default</code>, or define a global <code>App()</code>.</div>
          <div class="wrap">
            <div id="root"></div>
            <div id="log" class="hint">Ready.</div>
          </div>
          <script>
            (function () {
              const logEl = document.getElementById('log');
              function log(msg, isErr) {
                logEl.textContent = String(msg);
                logEl.className = isErr ? 'err' : 'hint';
              }

              const entryId = \(entryJSON);
              const sources = \(modulesJSON);
              if (!window.React || !window.ReactDOM || !window.Babel) {
                log("Missing bundled JS runtime (React/ReactDOM/Babel).", true);
                return;
              }

              // Minimal externals for React runtimes.
              function requireExternal(id) {
                if (id === 'react') return window.React;
                if (id === 'react-dom') return window.ReactDOM;
                if (id === 'react-dom/client') {
                  return { createRoot: window.ReactDOM.createRoot ? window.ReactDOM.createRoot.bind(window.ReactDOM) : undefined };
                }
                if (id === 'react/jsx-runtime' || id === 'react/jsx-dev-runtime') {
                  return {
                    Fragment: window.React.Fragment,
                    jsx: window.React.createElement,
                    jsxs: window.React.createElement
                  };
                }
                return null;
              }

              // CommonJS module loader with caching.
              const moduleFns = Object.create(null);
              const moduleCache = Object.create(null);

              function compileToCommonJS(id, src) {
                // Prefer automatic runtime so React import isn't required (React 17+ ergonomics).
                let opts = {
                  presets: [['react', { runtime: 'automatic' }]],
                  filename: id
                };
                try {
                  opts.plugins = ['transform-modules-commonjs'];
                  return Babel.transform(src, opts).code;
                } catch (e) {
                  // Fallback: try without module transform (imports/exports will not work).
                  opts = { presets: [['react', { runtime: 'automatic' }]], filename: id };
                  return Babel.transform(src, opts).code;
                }
              }

              function defineModule(id) {
                if (moduleFns[id]) return;
                const src = sources[id];
                if (typeof src !== 'string') throw new Error('Missing source for module: ' + id);
                const compiled = compileToCommonJS(id, src);
                moduleFns[id] = new Function('module', 'exports', 'require', compiled + '\\n//# sourceURL=' + id);
              }

              function require(id) {
                const ext = requireExternal(id);
                if (ext) return ext;
                if (moduleCache[id]) return moduleCache[id].exports;
                defineModule(id);
                const m = { exports: {} };
                moduleCache[id] = m;
                moduleFns[id](m, m.exports, require);
                return m.exports;
              }

              try {
                const rootEl = document.getElementById('root');
                const root = ReactDOM.createRoot ? ReactDOM.createRoot(rootEl) : null;
                let app = null;

                // Load entry module; prefer exported default or named App export.
                const entryExports = require(entryId) || {};
                if (typeof entryExports.default === 'function') app = entryExports.default;
                else if (typeof entryExports.App === 'function') app = entryExports.App;
                else if (typeof window.App === 'function') app = window.App;

                if (!app) {
                  log("No App component found. Export default App, export { App }, or define global App().", true);
                  return;
                }

                const element = React.createElement(app, null);
                if (root) {
                  root.render(element);
                } else if (ReactDOM.render) {
                  ReactDOM.render(element, rootEl);
                } else {
                  log("ReactDOM render API not available.", true);
                  return;
                }

                log("Rendered App().");
              } catch (e) {
                log(String(e && e.stack ? e.stack : e), true);
              }
            })();
          </script>
        </body>
        </html>
        """
    }
}

struct JSXWebView: NSViewRepresentable {
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

// MARK: - Local Bundling (Offline Imports)

struct LocalJSXBundle {
    var entryModuleID: String
    var modules: [String: String]

    static func singleFile(source: String) -> LocalJSXBundle {
        LocalJSXBundle(entryModuleID: "/entry.jsx", modules: ["/entry.jsx": source])
    }
}

enum LocalJSXBundlerError: LocalizedError {
    case entryNotAFile
    case tooManyFiles
    case fileReadFailed(String)
    case illegalImport(String)

    var errorDescription: String? {
        switch self {
        case .entryNotAFile: return "Entry file is missing."
        case .tooManyFiles: return "Too many imported files."
        case .fileReadFailed(let p): return "Failed reading: \(p)"
        case .illegalImport(let s): return "Unsupported import: \(s)"
        }
    }
}

/// Best-effort local bundler for relative imports (./, ../). This is intentionally limited:
/// - No node_modules resolution
/// - No URL imports
/// - Supports .js/.jsx extensions (and index.*)
final class LocalJSXBundler {
    private let maxFiles = 200
    private let allowedExtensions = ["js", "jsx"]

    func bundle(entry: URL) throws -> LocalJSXBundle {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw LocalJSXBundlerError.entryNotAFile
        }

        // Constrain module IDs to be stable and safe: absolute file path string.
        // WKWebView uses this as "filename" for Babel + sourceURL.
        let entryID = entry.path

        var modules: [String: String] = [:]
        var visited: Set<String> = []

        try loadRecursive(url: entry, moduleID: entryID, modules: &modules, visited: &visited)
        return LocalJSXBundle(entryModuleID: entryID, modules: modules)
    }

    private func loadRecursive(url: URL, moduleID: String, modules: inout [String: String], visited: inout Set<String>) throws {
        if visited.contains(moduleID) { return }
        visited.insert(moduleID)

        if visited.count > maxFiles {
            throw LocalJSXBundlerError.tooManyFiles
        }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            throw LocalJSXBundlerError.fileReadFailed(url.path)
        }

        modules[moduleID] = text

        for spec in extractImportSpecifiers(from: text) {
            // Leave external imports (react, etc.) to the runtime externals mapping.
            if spec.hasPrefix("http://") || spec.hasPrefix("https://") {
                throw LocalJSXBundlerError.illegalImport(spec)
            }
            if spec.hasPrefix(".") {
                let depURL = try resolveRelativeImport(specifier: spec, from: url)
                try loadRecursive(url: depURL, moduleID: depURL.path, modules: &modules, visited: &visited)
                continue
            }
        }
    }

    private func extractImportSpecifiers(from source: String) -> [String] {
        // Very small, best-effort scanner (no full JS parser).
        // import ... from 'x' / import 'x'
        let patterns = [
            #"(?m)^\s*import\s+.*?\s+from\s+['"]([^'"]+)['"]\s*;?\s*$"#,
            #"(?m)^\s*import\s+['"]([^'"]+)['"]\s*;?\s*$"#
        ]
        var results: [String] = []
        for pat in patterns {
            if let re = try? NSRegularExpression(pattern: pat, options: []) {
                let ns = source as NSString
                let range = NSRange(location: 0, length: ns.length)
                re.enumerateMatches(in: source, range: range) { m, _, _ in
                    guard let m, m.numberOfRanges >= 2 else { return }
                    let r = m.range(at: 1)
                    if r.location != NSNotFound {
                        results.append(ns.substring(with: r))
                    }
                }
            }
        }
        return results
    }

    private func resolveRelativeImport(specifier: String, from fileURL: URL) throws -> URL {
        let baseDir = fileURL.deletingLastPathComponent()
        let raw = baseDir.appendingPathComponent(specifier)

        // If specifier already includes extension, try as-is.
        if allowedExtensions.contains(raw.pathExtension.lowercased()) {
            return raw.standardizedFileURL
        }

        // Try file with extension.
        for ext in allowedExtensions {
            let candidate = raw.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }

        // Try directory index.{js,jsx}
        for ext in allowedExtensions {
            let candidate = raw.appendingPathComponent("index").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }

        throw LocalJSXBundlerError.fileReadFailed(raw.path)
    }
}
