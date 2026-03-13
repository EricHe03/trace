# MITM Certificate Model

This page explains how Trace generates and manages TLS certificates for HTTPS interception.

## Why a custom root CA is needed

HTTPS uses TLS to provide authentication (you are talking to the real server) and confidentiality (nobody can read the traffic). For Trace to read HTTPS traffic, it must act as a TLS terminator: it presents a certificate to the client app that the client accepts, then opens a separate TLS connection to the real server.

iOS apps validate server certificates against the system trust store. A certificate Trace generates on the fly will only be accepted if it is signed by a CA that iOS trusts. Trace installs its own root CA into the device trust store. The user must explicitly grant full trust for the CA; iOS does not do this automatically when a profile is installed.

## Root CA generation

Trace generates the root CA private key and self-signed certificate the first time you go through **Settings → Certificate Setup**. The implementation lives in `TraceSecurity`.

- Key type: RSA 2048 or EC P-256 (implementation detail; subject to change)
- The private key is stored in the iOS Keychain under the shared keychain group (`$(AppIdentifierPrefix)com.justin.trace`)
- The certificate is stored in the App Group container and shared with the VPN extension
- Nothing is sent to any server. The root CA is unique to your device.

## Per-host certificate generation

When Trace intercepts a TLS `ClientHello`, it reads the SNI (Server Name Indication) field to determine the hostname. It then:

1. Generates an ephemeral leaf certificate for that hostname.
2. Signs it with the locally-stored root CA private key.
3. Presents the leaf certificate to the client app.

Leaf certificates are cached in memory during the session. They are not persisted to disk.

The MITM then connects to the real server using the device's normal system trust store, verifying the real certificate chain. If the real server has a valid certificate, Trace decrypts the traffic and re-encrypts it for the client. If the real server presents an invalid certificate (expired, wrong hostname, etc.), Trace reports the error to the client.

## What the client app sees

From the client app's perspective:

- The TLS session is with Trace, not the real server.
- The leaf certificate is issued by the Trace root CA.
- If the root CA is trusted, TLS succeeds and the app sees what it expects (HTTP headers, response codes, etc.).
- The app cannot distinguish Trace's leaf cert from a server-issued cert by inspecting headers or response bodies alone.

Certificate pinning defeats this: an app that compares the leaf certificate's public key or fingerprint against a hardcoded expected value will reject the Trace-generated cert.

## Certificate pinning

Apps use several pinning strategies:

| Strategy | How it works | Trace's ability to intercept |
|---|---|---|
| CA pinning | App only accepts certs from specific CAs | Blocked if Trace's CA is not in the pin set |
| Leaf pinning | App checks the exact leaf cert fingerprint | Always blocked |
| Public key pinning (HPKP-style) | App checks the server's public key | Always blocked |
| `SecTrust` custom evaluation | App overrides default trust validation | Blocked if the code rejects non-built-in roots |

There is no general workaround for pinning in Trace. Pinned apps appear in the Network tab as opaque TLS flows (you see timing and byte counts but not decrypted content).

## Root CA rotation

If you need to regenerate the root CA (for example, after reinstalling Trace):

1. Remove the old Trace CA from iOS **Settings → General → About → Certificate Trust Settings**.
2. Open Trace and go to **Settings → Certificate Setup → Regenerate CA**.
3. Re-install and re-trust the new profile.

Previously captured sessions that were decrypted with the old CA remain readable in Trace's database. New captures use the new CA.

## Security scope

The root CA is intentionally scoped to a single physical device. It is not designed to be exported or used on other devices. Exporting the private key and installing it elsewhere would allow MITM on any device that trusts it — treat the CA material with appropriate care.
