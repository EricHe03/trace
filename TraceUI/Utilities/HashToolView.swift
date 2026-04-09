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

    @State private var md5Hash = ""
    @State private var sha1Hash = ""
    @State private var sha256Hash = ""
    @State private var sha512Hash = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lg) {
                // Input section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.down.doc")
                            .foregroundStyle(DesignSystem.Colors.info)
                            .imageScale(.medium)
                        Text("Input")
                            .font(.headline)

                        Spacer()

                        Button("Clear") {
                            inputText = ""
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                        .disabled(inputText.isEmpty)
                        .accessibilityLabel("Clear input")
                        .accessibilityHint("Double tap to clear the input text")
                    }

                    TextEditor(text: $inputText)
                        .frame(minHeight: DesignSystem.Form.textEditorMinHeightSmall)
                        .font(DesignSystem.Typography.monospacedFont)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(DesignSystem.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .fill(DesignSystem.Form.textEditorBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                                .stroke(DesignSystem.Colors.muted.opacity(0.3), lineWidth: 1)
                        )
                        .accessibilityLabel("Input text")
                        .accessibilityHint("Enter text to generate hashes")
                        .onChangeCompat(of: inputText) { recomputeHashes() }
                }
                .padding(.horizontal)

                // HMAC options
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Toggle("Use HMAC", isOn: $useHMAC)
                        .accessibilityHint("Use HMAC for hash-based message authentication")
                        .onChangeCompat(of: useHMAC) { recomputeHashes() }

                    if useHMAC {
                        TextField("HMAC Key", text: $hmacKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(DesignSystem.Spacing.md)
                            .background(DesignSystem.Colors.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("HMAC key")
                            .accessibilityHint("Enter the key for HMAC authentication")
                            .onChangeCompat(of: hmacKey) { recomputeHashes() }
                    }

                    Text(useHMAC ? "Hash-based Message Authentication Code" : "Standard hash functions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                        .fill(DesignSystem.Colors.muted.opacity(0.1))
                )
                .padding(.horizontal)

                // Output section
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.up.doc")
                            .foregroundStyle(DesignSystem.Colors.success)
                            .imageScale(.medium)
                        Text("Hashes")
                            .font(.headline)
                    }
                    .padding(.horizontal)

                    VStack(spacing: DesignSystem.Spacing.md) {
                        HashResultCard(algorithm: "MD5", hash: md5Hash, color: DesignSystem.Colors.accent) {
                            copyHash("MD5", hash: md5Hash)
                        }
                        HashResultCard(algorithm: "SHA1", hash: sha1Hash, color: DesignSystem.Colors.success) {
                            copyHash("SHA1", hash: sha1Hash)
                        }
                        HashResultCard(algorithm: "SHA256", hash: sha256Hash, color: DesignSystem.Colors.warning) {
                            copyHash("SHA256", hash: sha256Hash)
                        }
                        HashResultCard(algorithm: "SHA512", hash: sha512Hash, color: DesignSystem.Colors.accentAlt) {
                            copyHash("SHA512", hash: sha512Hash)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: DesignSystem.Spacing.md)
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("Hash")
    }

    // MARK: - Hash Computations

    private func recomputeHashes() {
        md5Hash = computeMD5()
        sha1Hash = computeSHA1()
        sha256Hash = computeSHA256()
        sha512Hash = computeSHA512()
    }

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
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(color)
                }
                .buttonStyle(.bordered)
                .tint(color)
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
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(algorithm) hash\(hash.isEmpty ? "" : ": \(hash)")")
    }
}

#Preview {
    HashToolView()
}
