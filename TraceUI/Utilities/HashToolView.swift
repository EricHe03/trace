//
//  HashToolView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import CryptoKit
import SwiftUI

/// Presents a hashing tool with optional HMAC support.
public struct HashToolView: View {
    @State private var inputText = ""
    @State private var hmacKey = ""
    @State private var useHMAC = false
    @State private var toastMessage: String?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lgPlus) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Input")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                        }
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                        .accessibilityLabel("Clear input")
                        .accessibilityHint("Double tap to clear the input text")
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightSmall)
                        .font(DesignSystem.Typography.monospacedFont)
                        .formTextEditorStyle()
                        .accessibilityLabel("Input text")
                        .accessibilityHint("Enter text to generate hashes")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Toggle("Use HMAC", isOn: $useHMAC)
                        .accessibilityHint("Use HMAC for hash-based message authentication")

                    if useHMAC {
                        TextField("HMAC Key", text: $hmacKey)
                            .padding(DesignSystem.Spacing.md)
                            .background(DesignSystem.Colors.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("HMAC key")
                            .accessibilityHint("Enter the key for HMAC authentication")
                    }

                    Text(useHMAC ? "Hash-based Message Authentication Code" : "Standard hash functions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                VStack(spacing: DesignSystem.Spacing.lg) {
                    HashResultCard(
                        algorithm: "MD5",
                        hash: computeMD5(),
                        color: DesignSystem.Colors.accent
                    ) {
                        copyHash("MD5", hash: computeMD5())
                    }

                    HashResultCard(
                        algorithm: "SHA1",
                        hash: computeSHA1(),
                        color: DesignSystem.Colors.success
                    ) {
                        copyHash("SHA1", hash: computeSHA1())
                    }

                    HashResultCard(
                        algorithm: "SHA256",
                        hash: computeSHA256(),
                        color: DesignSystem.Colors.warning
                    ) {
                        copyHash("SHA256", hash: computeSHA256())
                    }

                    HashResultCard(
                        algorithm: "SHA512",
                        hash: computeSHA512(),
                        color: DesignSystem.Colors.accentAlt
                    ) {
                        copyHash("SHA512", hash: computeSHA512())
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("Hash")
    }

    // MARK: - Hash Computations

    private func computeMD5() -> String {
        guard !inputText.isEmpty else { return "" }
        guard let data = inputText.data(using: .utf8) else { return "" }

        if useHMAC, !hmacKey.isEmpty {
            guard let keyData = hmacKey.data(using: .utf8) else { return "" }
            let key = SymmetricKey(data: keyData)
            let hmac = HMAC<Insecure.MD5>.authenticationCode(for: data, using: key)
            return hmac.map { String(format: "%02x", $0) }.joined()
        } else {
            let digest = Insecure.MD5.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func computeSHA1() -> String {
        guard !inputText.isEmpty else { return "" }
        guard let data = inputText.data(using: .utf8) else { return "" }

        if useHMAC, !hmacKey.isEmpty {
            guard let keyData = hmacKey.data(using: .utf8) else { return "" }
            let key = SymmetricKey(data: keyData)
            let hmac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key)
            return hmac.map { String(format: "%02x", $0) }.joined()
        } else {
            let digest = Insecure.SHA1.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func computeSHA256() -> String {
        guard !inputText.isEmpty else { return "" }
        guard let data = inputText.data(using: .utf8) else { return "" }

        if useHMAC, !hmacKey.isEmpty {
            guard let keyData = hmacKey.data(using: .utf8) else { return "" }
            let key = SymmetricKey(data: keyData)
            let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
            return hmac.map { String(format: "%02x", $0) }.joined()
        } else {
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func computeSHA512() -> String {
        guard !inputText.isEmpty else { return "" }
        guard let data = inputText.data(using: .utf8) else { return "" }

        if useHMAC, !hmacKey.isEmpty {
            guard let keyData = hmacKey.data(using: .utf8) else { return "" }
            let key = SymmetricKey(data: keyData)
            let hmac = HMAC<SHA512>.authenticationCode(for: data, using: key)
            return hmac.map { String(format: "%02x", $0) }.joined()
        } else {
            let digest = SHA512.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func copyHash(_ algorithm: String, hash: String) {
        guard !hash.isEmpty else { return }

        UIPasteboard.general.string = hash
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = "Copied \(algorithm) hash"
        }
    }
}

/// Presents a single hash output with copy action.
public struct HashResultCard: View {
    public let algorithm: String
    public let hash: String
    public let color: Color
    public let onCopy: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text(algorithm)
                    .font(.headline)
                    .foregroundStyle(color)

                Spacer()

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(color)
                }
                .disabled(hash.isEmpty)
                .accessibilityLabel("Copy \(algorithm) hash")
                .accessibilityHint("Double tap to copy the \(algorithm) hash to clipboard")
            }

            if hash.isEmpty {
                Text("Enter text to generate hash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(hash)
                    .font(DesignSystem.Typography.monospacedCaptionFont)
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(algorithm) hash\(hash.isEmpty ? "" : ": \(hash)")")
    }
}

#Preview {
    HashToolView()
}
