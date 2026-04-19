import SwiftUI
@preconcurrency import WebKit

// Landing screen backed by the designer-exported offline HTML bundle.
//
// Two subtleties this view has to handle carefully:
//
//   1. The bundler calls `document.documentElement.replaceWith(...)` after
//      unpacking its asset manifest. That wipes out any <style> we injected
//      at document-start. Solution: a MutationObserver re-applies the style
//      every time the DOM is rebuilt.
//
//   2. The real button's `onclick="openApp()"` does `location.href =
//      'screens/home.html'` — a nav we'd rather not attempt. Instead of
//      fighting to override the JS (the bundler redefines it post-replace),
//      we catch the navigation in WKNavigationDelegate.decidePolicyFor.

struct OttoLandingWebView: UIViewRepresentable {
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "otto")

        let bridgeScript = WKUserScript(
            source: #"""
            (function() {
              var STYLE_ID = '__otto_chrome_strip';
              var CSS = [
                'html, body {',
                '  margin: 0 !important; padding: 0 !important;',
                '  width: 100% !important; height: 100% !important;',
                '  overflow: hidden !important;',
                '  background: #05080f !important;',
                '  display: block !important;',
                '}',
                // Kill everything that's canvas-chrome in the designer preview.
                '.page { padding: 0 !important; gap: 0 !important; min-height: 100vh !important; background: transparent !important; }',
                '.page-title { display: none !important; }',       // "OTTO · ONBOARDING"
                '.page > .meta { display: none !important; }',     // "← All screens" footer
                '.tweaks { display: none !important; }',           // design-tool panel
                '.statusbar { display: none !important; }',        // fake 9:41
                '.home-indicator { display: none !important; }',   // fake pill
                '.island { display: none !important; }',           // fake dynamic island — iOS draws its own
                '.talk-btn { display: none !important; }',         // tap-anywhere does the same thing
                // Flatten the simulated phone bezel so the design fills edge-to-edge.
                '.phone {',
                '  position: fixed !important;',
                '  inset: 0 !important;',
                '  width: 100vw !important; height: 100vh !important;',
                '  border-radius: 0 !important;',
                '  box-shadow: none !important;',
                '  overflow: hidden !important;',
                '}',
                '.otto-start-hint {',
                '  font-family: \'Geist Mono\', ui-monospace, monospace;',
                '  font-size: 11px; letter-spacing: 0.28em; text-transform: uppercase;',
                '  color: rgba(232, 238, 248, 0.55);',
                '  margin-top: 4px;',
                '  text-align: center;',
                '}'
              ].join('\n');

              function injectStyle() {
                if (document.getElementById(STYLE_ID)) return;
                var s = document.createElement('style');
                s.id = STYLE_ID;
                s.textContent = CSS;
                (document.head || document.documentElement).appendChild(s);
              }

              // Insert a "Tap anywhere to start" line immediately after the
              // tagline. Idempotent via a dataset flag so the MutationObserver
              // can call this on every rebuild without stacking duplicates.
              function addStartHint() {
                var tagline = document.querySelector('.tagline');
                if (!tagline || tagline.dataset.ottoHinted === '1') return;
                var hint = document.createElement('div');
                hint.className = 'otto-start-hint';
                hint.textContent = 'Tap anywhere to start';
                tagline.insertAdjacentElement('afterend', hint);
                tagline.dataset.ottoHinted = '1';
              }

              // Force the MONO palette on the phone mockup. The bundled HTML
              // has a TWEAKS const that sets palette via `data-palette`; here
              // we override whatever the design-tool stored so the landing
              // always renders in our selected palette.
              function forceMonoPalette() {
                var phone = document.getElementById('phone');
                if (phone && phone.dataset.palette !== 'mono') {
                  phone.dataset.palette = 'mono';
                }
              }

              // The bundler replaces documentElement after unpacking assets, so
              // our initial <style> vanishes. Watch the document and re-inject.
              function armObserver() {
                try {
                  var mo = new MutationObserver(function() {
                    injectStyle();
                    addStartHint();
                    forceMonoPalette();
                  });
                  mo.observe(document.documentElement, { childList: true, subtree: true });
                } catch (e) {}
              }

              injectStyle();
              addStartHint();
              forceMonoPalette();
              armObserver();

              // Tap-anywhere safety net. Navigation interception (Swift side)
              // handles the real button; this catches everything else.
              function tap() {
                try { window.webkit.messageHandlers.otto.postMessage('tap'); } catch (e) {}
              }
              document.addEventListener('pointerdown', tap, true);
              document.addEventListener('click', tap, true);
            })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContent.addUserScript(bridgeScript)

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.showsVerticalScrollIndicator = false

        if let url = Bundle.main.url(forResource: "OttoLanding", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.loadHTMLString("""
            <html><body style="background:#0b0611;color:#bbb;font:14px -apple-system;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
            OttoLanding.html missing from bundle
            </body></html>
            """, baseURL: nil)
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onTap: () -> Void
        private var fired = false
        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            fireOnce()
        }

        // Intercept the button's `location.href = 'screens/home.html'` and
        // any other navigation attempt — fire the bridge instead of actually
        // navigating (those URLs don't exist in our bundle anyway).
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial load of the bundled OttoLanding.html itself.
            if navigationAction.navigationType == .other,
               let url = navigationAction.request.url,
               url.lastPathComponent == "OttoLanding.html" {
                decisionHandler(.allow)
                return
            }
            // Anything else (button clicks, <a href="screens/home.html">) =
            // user wants to enter the app.
            if navigationAction.navigationType == .linkActivated
                || navigationAction.navigationType == .formSubmitted
                || navigationAction.navigationType == .other {
                // .other also covers `location.href = ...` from scripts.
                if let url = navigationAction.request.url, url.lastPathComponent == "OttoLanding.html" {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                    fireOnce()
                }
                return
            }
            decisionHandler(.allow)
        }

        private func fireOnce() {
            guard !fired else { return }
            fired = true
            DispatchQueue.main.async { self.onTap() }
        }
    }
}
