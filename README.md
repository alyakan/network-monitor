# Network Monitor

Minimal macOS HTTP/HTTPS proxy for watching what the Lumiform iOS app sends during development. Swift + SwiftUI, no configuration files.

## Run

```
make run            # or: open Package.swift in Xcode and run the NetworkMonitor scheme
make app            # builds build/NetworkMonitor.app
```

The first launch takes a few minutes while SwiftNIO and BoringSSL compile.

## Setup

Press **Start**, then open **Setup** in the toolbar.

**Simulator**
1. Setup → *Install certificate in booted simulator* (runs `xcrun simctl keychain booted add-root-cert`).
2. Setup → *Enable macOS proxy*. The simulator uses the Mac's system proxy. Disable it when done; the app also disables it on Stop/Quit.

**Device**
1. Wi‑Fi → ⓘ → Configure Proxy → Manual → Mac IP and port shown in Setup.
2. Open `http://<mac-ip>:8888` in Safari, download the certificate, install the profile.
3. Settings → General → About → Certificate Trust Settings → enable full trust.

The root CA lives in `~/Library/Application Support/NetworkMonitor/`. Deleting the folder regenerates it (devices must then re-trust the new certificate).

## Limitations

- Requests and responses are fully buffered; streaming, WebSockets and HTTP/2 to the device are not supported (upstream HTTP/2 is fine).
- Hosts with certificate pinning (Apple system services, some SDKs) fail the TLS handshake and don't appear.
- Response headers pass through `HTTPURLResponse`, so multiple `Set-Cookie` headers are joined.
- Upstream requests go through `URLSession`, which adds `Accept-Encoding`, `Accept-Language` and `Priority` when the device omits them. The list shows what the device actually sent.
