//
//  TLSDetailSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

/// Displays TLS connection information including ALPN negotiation.
struct TLSDetailSection: View {
    let tlsInfo: TLSConnectionInfo

    var body: some View {
        SectionCard(title: "TLS Connection", systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                connectionSummary

                if let alpnProtocol = tlsInfo.alpnProtocol, !alpnProtocol.isEmpty {
                    Divider()
                    alpnSection(negotiatedProtocol: alpnProtocol)
                }

                if let certChain = tlsInfo.certificateChain, !certChain.isEmpty {
                    Divider()
                    certificateChainSection(certChain)
                }
            }
        }
    }

    private var connectionSummary: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            LabelValueRow(label: "Protocol", value: tlsInfo.protocolVersion)

            if let cipherSuite = tlsInfo.cipherSuite {
                LabelValueRow(label: "Cipher Suite", value: cipherSuite)
            }

            LabelValueRow(
                label: "Certificate",
                value: tlsInfo.certificateTrusted ? "Trusted" : "Not Trusted",
                valueColor: tlsInfo.certificateTrusted ? DesignSystem.Colors.success : DesignSystem.Colors.warning
            )
        }
    }

    private func alpnSection(negotiatedProtocol: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("ALPN Negotiation")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            HStack {
                Text("Negotiated:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                protocolChip(
                    negotiatedProtocol,
                    background: DesignSystem.Colors.success.opacity(0.15),
                    foreground: DesignSystem.Colors.success
                )

                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            if let offered = tlsInfo.alpnOffered, !offered.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Client Offered:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        ForEach(offered, id: \.self) { protocolName in
                            protocolChip(
                                protocolName,
                                background: DesignSystem.Colors.accent.opacity(0.1),
                                foreground: DesignSystem.Colors.accent
                            )
                        }
                    }
                }
            }

            if let available = tlsInfo.alpnAvailable, !available.isEmpty {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Server Advertised:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        ForEach(available, id: \.self) { protocolName in
                            protocolChip(
                                protocolName,
                                background: DesignSystem.Colors.warning.opacity(0.12),
                                foreground: DesignSystem.Colors.warning
                            )
                        }
                    }
                }
            }
        }
    }

    private func certificateChainSection(_ certChain: [CertificateInfo]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Certificate Chain")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Text("\(certChain.count) cert\(certChain.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(certChain) { cert in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text(cert.subject)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("Issuer: \(cert.issuer)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if cert.isValid {
                            statusTag(
                                text: "Valid",
                                icon: "checkmark.circle.fill",
                                color: DesignSystem.Colors.success
                            )
                        } else {
                            statusTag(
                                text: "Invalid/Expired",
                                icon: "xmark.circle.fill",
                                color: DesignSystem.Colors.danger
                            )
                        }

                        if cert.isExpiringSoon {
                            statusTag(
                                text: "Expiring Soon",
                                icon: "exclamationmark.triangle.fill",
                                color: DesignSystem.Colors.warning
                            )
                        }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            }
        }
    }

    private func protocolChip(_ title: String, background: Color, foreground: Color) -> some View {
        Text(title)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.sm))
    }

    private func statusTag(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(color)
    }
}

private struct LabelValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(valueColor)
        }
    }
}

#Preview("With ALPN") {
    ScrollView {
        TLSDetailSection(tlsInfo: TLSConnectionInfo(
            protocolVersion: "TLSv1.3",
            cipherSuite: "TLS_AES_128_GCM_SHA256",
            certificatePinningEnabled: false,
            certificateTrusted: true,
            alpnProtocol: "h2",
            alpnOffered: ["h2", "http/1.1"],
            alpnAvailable: ["h2", "http/1.1"]
        ))
        .padding()
    }
}
