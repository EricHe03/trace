//
//  TLSPassthroughSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

/// Shows explanation when a request was not decrypted (TLS passthrough)
struct TLSPassthroughSection: View {
    let request: NetworkRequest

    var body: some View {
        if request.isTLSPassthrough {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                // Header
                HStack {
                    Image(systemName: request.isPinningLikely ? "lock.shield" : "lock.open")
                        .foregroundStyle(request.isPinningLikely ? .red : .orange)
                    Text(request.isPinningLikely ? "Certificate Pinning Detected" : "TLS Not Decrypted")
                        .font(.headline)
                }

                // Explanation
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    if request.isPinningLikely {
                        explanationText(
                            title: "Why can't this be decrypted?",
                            description: "This app uses certificate pinning, which means it only accepts specific certificates that it knows about. Our MITM certificate was rejected by the app."
                        )

                        explanationText(
                            title: "What is certificate pinning?",
                            description: "Certificate pinning is a security feature that prevents man-in-the-middle attacks by only trusting pre-defined certificates. Many banking, security, and enterprise apps use this."
                        )

                        explanationText(
                            title: "Can I bypass this?",
                            description: "No - pinning is designed to prevent exactly what we're trying to do. Decrypting traffic from pinned apps would require modifying the app itself."
                        )
                    } else {
                        explanationText(
                            title: "Why wasn't this decrypted?",
                            description: request.tlsPassthroughReason ?? "HTTPS decryption was bypassed for this request."
                        )

                        // Possible reasons
                        Text("Possible reasons:")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 4) {
                            reasonItem("Domain not in MITM allowlist")
                            reasonItem("MITM interception disabled")
                            reasonItem("Root CA not trusted / full trust not enabled on device")
                            reasonItem("App/extension using different Root CAs (mismatch)")
                            reasonItem("TLS handshake failed (client rejected MITM certificate)")
                            reasonItem("Certificate pinning / system trust restriction (common in Apple services & banking apps)")
                        }
                        .padding(.leading, DesignSystem.Spacing.sm)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .fill(request.isPinningLikely ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
            )
        }
    }

    private func explanationText(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reasonItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    // Create a mock TLS passthrough request for preview
    let request = NetworkRequest(
        url: "https://api.example.com:443/",
        method: .connect,
        statusCode: nil,
        statusMessage: "TLS passthrough",
        duration: 0.1,
        requestHeaders: [
            TraceHTTPHeader(key: "Host", value: "api.example.com"),
            TraceHTTPHeader(key: "X-Trace-Note", value: "TLS not decryptable (MITM failed tls_server_connection_failed:The operation couldn’t be completed. (Network.NWError error -9825 - misc. bad certificate))")
        ]
    )

    return NavigationStack {
        ScrollView {
            TLSPassthroughSection(request: request)
                .padding()
        }
    }
}
