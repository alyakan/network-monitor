# Network Monitor

Minimal macOS HTTP/HTTPS proxy for watching what a mobile app sends during development, from the iOS simulator, an Android emulator or a real device. Swift + SwiftUI, no configuration files.

## Run

```
make run            # or: open Package.swift in Xcode and run the NetworkMonitor scheme
make app            # builds build/NetworkMonitor.app
```

The first launch takes a few minutes while SwiftNIO and BoringSSL compile.

## Setup

Press **Start**, then open **Setup** in the toolbar.

**iOS Simulator**
1. Setup → *Install certificate in booted simulator* (runs `xcrun simctl keychain booted add-root-cert`).
2. Setup → *Enable macOS proxy*. The simulator uses the Mac's system proxy. Disable it when done; the app also disables it on Stop/Quit.

**iOS device**
1. Wi‑Fi → ⓘ → Configure Proxy → Manual → Mac IP and port shown in Setup.
2. Open `http://<mac-ip>:8888` in Safari, download the certificate, install the profile.
3. Settings → General → About → Certificate Trust Settings → enable full trust.

**Android**
1. Wi‑Fi → network → Proxy: Manual → Mac IP and port. Emulator: Extended controls → Settings → Proxy, or `emulator -http-proxy 10.0.2.2:8888` (`10.0.2.2` is the host from inside the emulator).
2. Setup → *Push certificate to connected device (adb)*, or open `http://<mac-ip>:8888` in Chrome and download it.
3. Settings → Security → Encryption & credentials → Install a certificate → CA certificate → pick `NetworkMonitor-CA.crt` from Downloads.
4. Since Android 7, apps ignore user-installed CAs unless they opt in. For debug builds add `res/xml/network_security_config.xml`:

   ```xml
   <network-security-config>
       <debug-overrides>
           <trust-anchors>
               <certificates src="user" />
           </trust-anchors>
       </debug-overrides>
   </network-security-config>
   ```

   and reference it in the manifest with `android:networkSecurityConfig="@xml/network_security_config"`. `debug-overrides` only applies to debuggable builds. Chrome trusts user CAs without this.

The root CA lives in `~/Library/Application Support/NetworkMonitor/`. Deleting the folder regenerates it (devices must then re-trust the new certificate).

## Limitations

- Requests and responses are fully buffered; streaming, WebSockets and HTTP/2 to the device are not supported (upstream HTTP/2 is fine).
- Hosts with certificate pinning (Apple system services, some SDKs) fail the TLS handshake and don't appear.
- Response headers pass through `HTTPURLResponse`, so multiple `Set-Cookie` headers are joined.
- Upstream requests go through `URLSession`, which adds `Accept-Encoding`, `Accept-Language` and `Priority` when the device omits them. The list shows what the device actually sent.
