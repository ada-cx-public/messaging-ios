//
//  AdaHostPage.swift
//  AdaMessaging
//
//  Generates the HTML string loaded by the WKWebView.
//
//  The generated page:
//   1. Injects window.__ADA_INITIAL_STATE__ for instant UI rehydration on
//      WebView kill-and-restart cycles.
//   2. Runs the bridge adapter IIFE so native can receive events and send
//      commands via window.__ADA_BRIDGE_DISPATCH__.
//   3. Loads sdk.js from the Ada CDN (resolved from AdaEnvironment).
//   4. Boots AdaMessagingClient with the caller's configuration.
//
//  Security notes:
//   - All developer-supplied values are serialized via toScriptSafeJson()
//     which applies JSON encoding + </script> injection escaping.
//   - The CSP script-src is scoped to the CDN origin for the chosen
//     environment; all other origins are blocked.
//   - The bridge adapter receives commands through
//     window.__ADA_BRIDGE_DISPATCH__ — no user-supplied data is ever
//     interpolated into the evaluateJavaScript template.
//

import Foundation

// ---------------------------------------------------------------------------

// MARK: - HostPageOptions

// ---------------------------------------------------------------------------

struct HostPageOptions {
    let handle: String
    let environment: AdaEnvironment
    /// Legacy cluster string — overrides the cluster derived from `environment`
    /// when the caller explicitly passes one (backward compat).
    let cluster: String?
    let language: String?
    let greeting: String?
    let metaFields: [String: Any]?
    let initialState: [String: Any]?
}

// ---------------------------------------------------------------------------

// MARK: - generateHostPage

// ---------------------------------------------------------------------------

func generateHostPage(_ options: HostPageOptions) -> String {
    let cdnOrigin = options.environment.cdnOrigin
    let sdkUrl = options.environment.sdkUrl
    let cspConnectSrc = options.environment.cspConnectSrc

    // Serialize all developer-supplied config values once, safely.
    let initialStateJson = toScriptSafeJson(options.initialState as Any? ?? NSNull())
    let configJson = sdkConfigJson(for: options)

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0" />
      <meta http-equiv="Content-Security-Policy"
        content="default-src 'none';
                 script-src 'self' 'unsafe-inline' \(cdnOrigin);
                 connect-src \(cspConnectSrc);
                 frame-src \(cspConnectSrc);
                 img-src https: data:;
                 style-src 'unsafe-inline';
                 media-src https:;" />
      <style>
        html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: transparent; }
        #ada-root { width: 100%; height: 100%; }
      </style>
    </head>
    <body>
      <div id="ada-root"></div>

      <!-- Step 1: inject cached state for instant rehydration on WebView restart -->
      <script>window.__ADA_INITIAL_STATE__ = \(initialStateJson);</script>

      <!-- Step 2: bridge adapter IIFE (subscribes to events, exposes dispatcher) -->
      <script>\(bridgeAdapterScript)</script>

      <!-- Step 3: load and boot the Ada Messaging SDK -->
      <script type="module">
        import("\(sdkUrl)").then(({ createAdaEmbedInterface, dispatchEmbedLoaderInitialActionQueue }) => {
          const config = \(configJson);
          window.adaEmbed = createAdaEmbedInterface();
          dispatchEmbedLoaderInitialActionQueue(window.adaEmbed);
          window.adaEmbed.start({
            handle: config.handle,
            ...(config.cluster   ? { cluster:   config.cluster   } : {}),
            ...(config.language  ? { language:  config.language  } : {}),
            ...(config.greeting  ? { greeting:  config.greeting  } : {}),
            ...(config.metaFields ? { metaFields: config.metaFields } : {}),
            parentElement: document.getElementById("ada-root"),
          });
        }).catch((err) => {
          if (window.webkit?.messageHandlers?.adaBridge) {
            window.webkit.messageHandlers.adaBridge.postMessage({
              type: "sdk.error",
              error: String(err?.message ?? err),
            });
          }
        });
      </script>
    </body>
    </html>
    """
}

private func sdkConfigJson(for options: HostPageOptions) -> String {
    let clusterForSdk = options.cluster ?? impliedCluster(for: options.environment)

    return toScriptSafeJson([
        "handle": options.handle,
        "cluster": clusterForSdk as Any? ?? NSNull(),
        "language": options.language as Any? ?? NSNull(),
        "greeting": options.greeting as Any? ?? NSNull(),
        "metaFields": options.metaFields as Any? ?? NSNull(),
    ] as [String: Any])
}

private func impliedCluster(for environment: AdaEnvironment) -> String? {
    switch environment {
    case .preprod:
        "ada-dev2.support"
    default:
        nil
    }
}

// ---------------------------------------------------------------------------

// MARK: - toScriptSafeJson (private)

// ---------------------------------------------------------------------------

/// Serializes a value to JSON that is safe to inline inside a `<script>` tag.
///
/// `JSONSerialization` alone is not sufficient: if any string value contains
/// the sequence `</script>` the browser's HTML parser closes the script block
/// early, enabling injection. Replacing `<` and `>` with Unicode escapes
/// prevents this while keeping the JSON semantically identical.
private func toScriptSafeJson(_ value: Any) -> String {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    } catch {
        return "null"
    }
    guard var json = String(data: data, encoding: .utf8) else { return "null" }
    json = json.replacingOccurrences(of: "<", with: "\\u003c")
    json = json.replacingOccurrences(of: ">", with: "\\u003e")
    return json
}
