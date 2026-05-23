import SwiftUI
import WebKit

/// Mermaid 記法をブラウザで描画するビュー
/// mermaid.min.js を WKUserScript としてインジェクトするため、インターネット接続不要。
struct MermaidView: View {
    let code: String
    @State private var renderedHeight: CGFloat = 200
    @State private var renderFailed = false
    @State private var renderError: String? = nil  // 構文エラー等のメッセージ

    var body: some View {
        if renderFailed {
            if let error = renderError {
                mermaidErrorView(error: error)
            } else {
                mermaidFallbackView
            }
        } else {
            MermaidWebView(
                code: code,
                renderedHeight: $renderedHeight,
                renderFailed: $renderFailed,
                renderError: $renderError
            )
            .frame(height: renderedHeight)
            .cornerRadius(6)
        }
    }

    /// Mermaid 構文エラー表示（💣 + エラーメッセージ）
    private func mermaidErrorView(error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("💣")
                Text("Mermaid エラー")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 8)
            Text(error)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red.opacity(0.85))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.2), lineWidth: 1)
                )
        }
    }

    /// タイムアウト等でエラー詳細が取れない場合のフォールバック（コード表示）
    private var mermaidFallbackView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mermaid")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - mermaid.js キャッシュ
// ファイルを一度だけ読み込み、全 WKWebView インスタンスで共有する
private enum MermaidJS {
    static let source: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else {
            print("[MermaidView] ⚠️ mermaid.min.js をバンドルから読み込めませんでした")
            return ""
        }
        return js
    }()
}

// MARK: - 共通 WKWebView 生成ヘルパー
// mermaid.js を WKUserScript としてインジェクトし、クロスオリジン問題を回避する

private func makeMermaidWebViewConfig(coordinator: MermaidWebView.Coordinator) -> WKWebViewConfiguration {
    let userController = WKUserContentController()
    userController.add(coordinator, name: "mermaidBridge")

    if !MermaidJS.source.isEmpty {
        let script = WKUserScript(
            source: MermaidJS.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userController.addUserScript(script)
    }

    let config = WKWebViewConfiguration()
    config.userContentController = userController
    return config
}

// MARK: - Platform WebView wrapper

#if os(macOS)
/// スクロールイベントを親へ転送する WKWebView サブクラス（macOS 専用）
/// これにより Mermaid 図の上でのスクロール操作が ScrollView に伝わる
private class PassThroughWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // WKWebView のスクロール処理をスキップし、親ビュー（NSScrollView）へ転送
        nextResponder?.scrollWheel(with: event)
    }
}

struct MermaidWebView: NSViewRepresentable {
    let code: String
    @Binding var renderedHeight: CGFloat
    @Binding var renderFailed: Bool
    @Binding var renderError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight, renderFailed: $renderFailed, renderError: $renderError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = makeMermaidWebViewConfig(coordinator: context.coordinator)
        let webView = PassThroughWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoadedCode != code else { return }
        context.coordinator.lastLoadedCode = code
        webView.loadHTMLString(mermaidHTML(code: code), baseURL: nil)
    }
}
#else
struct MermaidWebView: UIViewRepresentable {
    let code: String
    @Binding var renderedHeight: CGFloat
    @Binding var renderFailed: Bool
    @Binding var renderError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(renderedHeight: $renderedHeight, renderFailed: $renderFailed, renderError: $renderError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = makeMermaidWebViewConfig(coordinator: context.coordinator)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoadedCode != code else { return }
        context.coordinator.lastLoadedCode = code
        webView.loadHTMLString(mermaidHTML(code: code), baseURL: nil)
    }
}
#endif

// MARK: - Shared Coordinator

extension MermaidWebView {
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var renderedHeight: CGFloat
        @Binding var renderFailed: Bool
        @Binding var renderError: String?
        /// 最後にロードしたコード。同じコードなら再ロードをスキップする
        var lastLoadedCode: String?

        init(renderedHeight: Binding<CGFloat>, renderFailed: Binding<Bool>, renderError: Binding<String?>) {
            _renderedHeight = renderedHeight
            _renderFailed = renderFailed
            _renderError = renderError
        }

        // JS → Swift メッセージ受信
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidBridge",
                  let dict = message.body as? [String: Any] else { return }

            if let error = dict["error"] as? String, !error.isEmpty {
                // 構文エラー or レンダリングエラー → エラーメッセージを保存して表示
                print("[MermaidView] 💣 render error: \(error)")
                DispatchQueue.main.async {
                    self.renderError = error
                    self.renderFailed = true
                }
            } else if let h = dict["height"] as? Double, h > 0 {
                // 正常レンダリング完了
                DispatchQueue.main.async {
                    self.renderedHeight = CGFloat(h) + 24  // padding
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.renderFailed = true }
        }
    }
}

// MARK: - HTML template
// mermaid.js は WKUserScript で既にインジェクト済みのため <script src> は不要

private func mermaidHTML(code: String) -> String {
    // JS インジェクション対策: mermaid コードを base64 でエンコード
    let encoded = Data(code.utf8).base64EncodedString()
    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body { background: transparent; padding: 8px; }
      #diagram { max-width: 100%; }
      svg { max-width: 100% !important; height: auto !important; }
    </style>
    </head>
    <body>
    <div id="diagram"></div>
    <script>
    (function() {
      try {
        const encoded = "\(encoded)";
        // atob() は Latin-1 バイト列を返すため TextDecoder で UTF-8 として再デコード
        const bytes = Uint8Array.from(atob(encoded), function(c){ return c.charCodeAt(0); });
        const src = new TextDecoder("utf-8").decode(bytes);
        mermaid.initialize({
          startOnLoad: false,
          theme: "neutral",
          securityLevel: "loose",
          flowchart: { useMaxWidth: true, htmlLabels: true }
        });
        mermaid.render("mermaid-svg", src).then(function(result) {
          const container = document.getElementById("diagram");
          container.innerHTML = result.svg;
          const svg = container.querySelector("svg");
          if (svg) {
            const st = document.createElementNS("http://www.w3.org/2000/svg", "style");
            st.textContent = [
              ".edgePath path,.edgePaths path,path.path,.flowchart-link,.transition{fill:none!important;stroke:#555!important;stroke-width:1.5px!important;}",
              "marker{overflow:visible!important;}",
              "marker path,.arrowheadPath{fill:#555555!important;stroke:none!important;}",
              "text,tspan{fill:#333333!important;font-family:-apple-system,Arial,sans-serif!important;}",
              ".node rect,.node circle,.node polygon,.node ellipse{fill:#f0f0f0!important;stroke:#666!important;}"
            ].join("\\n");
            svg.appendChild(st);
            svg.querySelectorAll("path").forEach(function(p) {
              if (p.closest("marker") || p.closest(".node")) return;
              p.style.fill = "none";
            });
            svg.querySelectorAll("text,tspan").forEach(function(el) {
              if (!el.closest("marker")) el.style.fill = "#333333";
            });
            svg.style.maxWidth = "100%";
            svg.style.height = "auto";
          }
          const h = document.body.scrollHeight;
          window.webkit.messageHandlers.mermaidBridge.postMessage({ height: h, error: "" });
        }).catch(function(err) {
          window.webkit.messageHandlers.mermaidBridge.postMessage({ height: 0, error: String(err) });
        });
      } catch(e) {
        window.webkit.messageHandlers.mermaidBridge.postMessage({ height: 0, error: String(e) });
      }
    })();
    </script>
    </body>
    </html>
    """
}
