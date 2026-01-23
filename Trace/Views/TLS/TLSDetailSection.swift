//
//  TLSDetailSection.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

/// Displays TLS connection information including ALPN negotiation
struct TLSDetailSection: View {
    let tlsInfo: TLSConnectionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Section Header
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(tlsInfo.certificateTrusted ? .green : .orange)
                Text("TLS Connection")
                    .font(.headline)
            }

            // TLS Version & Cipher
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                LabelValueRow(label: "Protocol", value: tlsInfo.protocolVersion)

                if let cipherSuite = tlsInfo.cipherSuite {
                    LabelValueRow(label: "Cipher Suite", value: cipherSuite)
                }

                LabelValueRow(
                    label: "Certificate",
                    value: tlsInfo.certificateTrusted ? "Trusted" : "Not Trusted",
                    valueColor: tlsInfo.certificateTrusted ? .green : .orange
                )
            }

            // ALPN Negotiation
            if let alpnProtocol = tlsInfo.alpnProtocol, !alpnProtocol.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("ALPN Negotiation")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    // Negotiated Protocol
                    HStack {
                        Text("Negotiated:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(alpnProtocol)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, DesignSystem.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    // Client Offered Protocols
                    if let offered = tlsInfo.alpnOffered, !offered.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Client Offered:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                ForEach(offered, id: \.self) { protocolName in
                                    Text(protocolName)
                                        .font(.system(.caption2, design: .monospaced))
                                        .padding(.horizontal, DesignSystem.Spacing.xs)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .foregroundStyle(.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }

                    // Server advertised/available protocols
                    if let available = tlsInfo.alpnAvailable, !available.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Server Advertised:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                ForEach(available, id: \.self) { protocolName in
                                    Text(protocolName)
                                        .font(.system(.caption2, design: .monospaced))
                                        .padding(.horizontal, DesignSystem.Spacing.xs)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.1))
                                        .foregroundStyle(.orange)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                        }
                    }
                }
            }

            // Certificate Chain
            if let certChain = tlsInfo.certificateChain, !certChain.isEmpty {
                Divider()

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

                            HStack {
                                if cert.isValid {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                    Text("Valid")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                    Text("Invalid/Expired")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }

                                if cert.isExpiringSoon {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Text("Expiring Soon")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(DesignSystem.Spacing.sm)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// Simple label-value row
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
