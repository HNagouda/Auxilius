import SwiftUI
import WebKit

/// Shows the transcript with its LaTeX typeset by KaTeX, which ships inside the app so it works offline.
struct TranscriptView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // Let the window background show through, so the pane follows light and dark mode like native views.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        if let page = Bundle.main.url(forResource: "transcript", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(text, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isLoaded = false
        private var pendingText: String?
        private var shownText: String?

        func show(_ text: String, in webView: WKWebView) {
            guard text != shownText else { return }

            pendingText = text
            guard isLoaded else { return }

            render(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            render(webView)
        }

        private func render(_ webView: WKWebView) {
            guard let text = pendingText,
                  let json = try? JSONSerialization.data(withJSONObject: [text]),
                  let argument = String(data: json, encoding: .utf8) else { return }

            // Passed as JSON so nothing in the transcript can break out of the string.
            // The trailing null stops WebKit from trying to hand back render's promise.
            webView.evaluateJavaScript("render(...\(argument)); null")
            shownText = text
            pendingText = nil
        }
    }
}
