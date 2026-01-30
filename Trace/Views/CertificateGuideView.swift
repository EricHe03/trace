//
//  CertificateGuideView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import Combine
import os
import SwiftUI
import TraceCore
import TraceSecurity
import TraceUI

struct CertificateGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shareSheetItem: ShareSheetItem?
    @State private var errorMessage: String?
    @State private var currentStep = 0
    @State private var isCertificateTrusted = false
    @State private var rootCAStatus: RootCAStatus = .notGenerated
    @State private var showReinstallWizard = false

    // Timer for periodic trust checking
    private let trustCheckTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    // Computed property to safely access current step with bounds checking
    private var safeCurrentStep: Int {
        min(max(0, currentStep), steps.count - 1)
    }

    let steps = [
        Step(
            title: "Export Certificate",
            description: "First, we need to export the Trace root CA certificate",
            systemImage: "arrow.down.doc",
            action: "Export Certificate"
        ),
        Step(
            title: "Install Profile",
            description: "Open Settings and install the certificate profile",
            systemImage: "gear",
            instructions: [
                "Tap 'Share' and save the certificate",
                "Open Settings app",
                "Go to General > VPN & Device Management",
                "Tap on 'Trace Root CA' profile",
                "Tap 'Install' and enter your passcode"
            ]
        ),
        Step(
            title: "Trust Certificate",
            description: "Enable full trust for the root certificate",
            systemImage: "checkmark.shield",
            instructions: [
                "Open Settings app",
                "Go to General > About > Certificate Trust Settings",
                "Enable full trust for 'Trace Network Debugger Root CA'",
                "Tap 'Continue' when prompted"
            ]
        ),
        Step(
            title: "All Done!",
            description: "You're ready to capture HTTPS traffic",
            systemImage: "checkmark.circle.fill",
            instructions: [
                "Return to Trace app",
                "Tap 'Start Capture' to begin",
                "HTTPS traffic will now be decrypted and captured"
            ]
        )
    ]

    var body: some View {
        NavigationStack {
            Group {
                if case .trustedAndMatching = rootCAStatus, !showReinstallWizard {
                    certificateInstalledView
                } else {
                    certificateSetupWizard
                }
            }
            .navigationTitle(showReinstallWizard ? "Re-install Certificate" : "HTTPS Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: shareSheetItem?.id) { _ in
                guard let item = shareSheetItem else { return }
                ShareHelper.presentShareSheet(items: item.items) {
                    shareSheetItem = nil
                }
            }
            .onAppear {
                checkTrustStatus()
            }
            .onReceive(trustCheckTimer) { _ in
                // Only check when on the trust step or when showing reinstall wizard
                if safeCurrentStep == 2 || showReinstallWizard {
                    checkTrustStatus()
                }
            }
        }
    }

    // MARK: - Certificate Installed View

    private var certificateInstalledView: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                // Success Hero
                successHero

                // Certificate Info Card
                certificateInfoCard

                // Status Card
                httpsStatusCard

                // Actions
                certificateActions

                // Error Message
                if let error = errorMessage {
                    errorBanner(error)
                }
            }
            .padding()
        }
    }

    private var successHero: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(DesignSystem.Colors.success)
                .tracePulseSymbolEffectIfAvailable(speed: 0.5)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Certificate Installed")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("HTTPS traffic decryption is ready")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private var certificateInfoCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label("Certificate Details", systemImage: "doc.text")
                .font(.headline)
                .foregroundStyle(.primary)

            Divider()

            VStack(spacing: DesignSystem.Spacing.md) {
                certificateInfoRow(
                    label: "Name",
                    value: "Trace Network Debugger Root CA"
                )

                if let creationDate = CertificateManager.shared.getRootCACreationDate() {
                    certificateInfoRow(
                        label: "Created",
                        value: creationDate.formatted(date: .abbreviated, time: .shortened)
                    )
                }

                if let fingerprint = CertificateManager.shared.getRootCAFingerprintFormatted() {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        Text("Fingerprint (SHA-256)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
        .shadow(
            color: DesignSystem.Shadow.md.color,
            radius: DesignSystem.Shadow.md.radius,
            x: DesignSystem.Shadow.md.x,
            y: DesignSystem.Shadow.md.y
        )
    }

    private func certificateInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }

    private var httpsStatusCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Label("HTTPS Decryption", systemImage: "lock.open.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Divider()

            HStack(spacing: DesignSystem.Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.success)
                    .font(.title3)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text("Enabled")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Text("All HTTPS traffic will be decrypted and captured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding()
        .background(DesignSystem.Colors.success.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
    }

    private var certificateActions: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Button {
                showReinstallWizard = true
                currentStep = 0
            } label: {
                Label("Re-install Certificate", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("Use this if you need to install the certificate on a new device profile or if HTTPS capture stops working.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Certificate Setup Wizard

    private var certificateSetupWizard: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.xl) {
                // Back button when reinstalling
                if showReinstallWizard, case .trustedAndMatching = rootCAStatus {
                    HStack {
                        Button {
                            showReinstallWizard = false
                        } label: {
                            Label("Back to Certificate", systemImage: "chevron.left")
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                }

                // Warning Banner
                warningBanner

                // Progress Indicator
                progressIndicator

                // Current Step
                stepCard(steps[safeCurrentStep])

                // Navigation Buttons
                navigationButtons

                // Error Message
                if let error = errorMessage {
                    errorBanner(error)
                }
            }
            .padding()
        }
    }

    // MARK: - UI Components

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.warning)
                Text("Security Notice")
                    .font(.headline)
            }

            Text("Installing this certificate allows Trace to decrypt HTTPS traffic. Only install if you trust this app. The certificate and all captured data stay on your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(DesignSystem.Colors.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    private var progressIndicator: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(0 ..< steps.count, id: \.self) { index in
                Circle()
                    .fill(index <= safeCurrentStep ? DesignSystem.Colors.accent : DesignSystem.Colors.muted.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("Step \(safeCurrentStep + 1) of \(steps.count)")
    }

    private func stepCard(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Step Header
            HStack(spacing: DesignSystem.Spacing.lg) {
                Image(systemName: stepIcon(for: step))
                    .font(.system(size: DesignSystem.IconSize.section))
                    .foregroundStyle(stepIconColor)
                    .frame(width: 60, height: 60)
                    .background(stepIconColor.opacity(0.1))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Step \(safeCurrentStep + 1) of \(steps.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(step.title)
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Spacer()
            }

            Text(step.description)
                .foregroundStyle(.secondary)

            // Action Button (for step 1)
            if safeCurrentStep == 0, let action = step.action {
                Button {
                    exportCertificate()
                } label: {
                    Label(action, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            // Trust status indicator (for step 3: "Trust Certificate")
            if safeCurrentStep == 2 {
                trustStatusView
            }

            // Recovery action (for step 1)
            if safeCurrentStep == 0 {
                Button(role: .destructive) {
                    regenerateRootCA()
                } label: {
                    Label("Regenerate Root CA (if HTTPS keeps failing)", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Instructions
            if let instructions = step.instructions {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                            Text("\(index + 1).")
                                .fontWeight(.semibold)
                                .foregroundStyle(DesignSystem.Colors.accent)
                                .frame(width: 24, alignment: .leading)

                            Text(instruction)
                                .font(.subheadline)
                        }
                    }
                }
                .padding()
                .background(DesignSystem.Colors.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
            }
        }
        .padding()
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.xl))
        .shadow(
            color: DesignSystem.Shadow.lg.color,
            radius: DesignSystem.Shadow.lg.radius,
            x: DesignSystem.Shadow.lg.x,
            y: DesignSystem.Shadow.lg.y
        )
    }

    private func stepIcon(for step: Step) -> String {
        // Show checkmark when certificate is trusted on trust step
        if safeCurrentStep == 2 && isCertificateTrusted {
            return "checkmark.shield.fill"
        }
        return step.systemImage
    }

    private var stepIconColor: Color {
        // Show success color when certificate is trusted on trust step
        if safeCurrentStep == 2 && isCertificateTrusted {
            return DesignSystem.Colors.success
        }
        return DesignSystem.Colors.accent
    }

    private var trustStatusView: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            if isCertificateTrusted {
                // Trusted state - clean success indicator
                Label("Certificate Trusted", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                // Not trusted state - show helpful hint
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text("Waiting for certificate to be trusted...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Complete the steps above, then return here. This will update automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(isCertificateTrusted ? DesignSystem.Colors.success.opacity(0.1) : DesignSystem.Colors.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
    }

    private var navigationButtons: some View {
        HStack(spacing: DesignSystem.Spacing.lg) {
            if safeCurrentStep > 0 {
                Button {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        currentStep = max(0, currentStep - 1)
                    }
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Previous step")
                .accessibilityHint("Moves to the previous setup step")
            }

            if safeCurrentStep < steps.count - 1 {
                Button {
                    withAnimation(DesignSystem.Accessibility.preferredAnimation) {
                        currentStep = min(steps.count - 1, currentStep + 1)
                    }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Next step")
                .accessibilityHint("Moves to the next setup step")
            } else {
                Button {
                    handleDone()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Done")
                .accessibilityHint("Closes the certificate guide")
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignSystem.Colors.danger)
                Text("Error")
                    .font(.headline)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(DesignSystem.Colors.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg))
    }

    // MARK: - Actions

    private func checkTrustStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let trusted = CertificateManager.shared.isRootCATrusted()

            // If trusted, save the current fingerprint as the "known good" one
            if trusted {
                CertificateManager.shared.saveKnownFingerprint()
            }

            DispatchQueue.main.async {
                self.isCertificateTrusted = trusted
                self.rootCAStatus = CertificateManager.shared.checkRootCAStatus()
            }
        }
    }

    private func exportCertificate() {
        errorMessage = nil

        do {
            SecurityLog.certificate.info("event=cert.export_begin outcome=pending")
            let url = try CertificateManager.shared.saveRootCertificateToFile()
            SecurityLog.certificate.info("event=cert.export_ready outcome=success")

            // Verify file is accessible
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(
                    domain: "CertificateExport",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Certificate file not found after creation"]
                )
            }

            // Small delay to ensure file system is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shareSheetItem = ShareSheetItem([url])
                SecurityLog.certificate.debug("event=cert.export_share_sheet outcome=presented")
            }
        } catch {
            SecurityLog.certificate.error(
                "event=cert.export outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "Failed to export certificate: \(error.localizedDescription)"
        }
    }

    private func regenerateRootCA() {
        errorMessage = nil
        isCertificateTrusted = false
        do {
            try CertificateManager.shared.resetRootCA()
            // Force regeneration now so export works immediately.
            _ = try CertificateManager.shared.getRootCA()
            SecurityLog.certificate.info("event=ca.regenerate outcome=success")
        } catch {
            SecurityLog.certificate.error(
                "event=ca.regenerate outcome=failure error=\(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "Failed to regenerate root CA: \(error.localizedDescription)"
        }
    }

    private func handleDone() {
        // If we were in reinstall mode and certificate is now trusted, exit reinstall wizard
        if showReinstallWizard, case .trustedAndMatching = rootCAStatus {
            showReinstallWizard = false
            currentStep = 0
        } else {
            // Dismiss the current presentation (sheet or navigation stack)
            dismiss()
        }
    }
}

// MARK: - Supporting Models

struct Step {
    let title: String
    let description: String
    let systemImage: String
    var action: String?
    var instructions: [String]?
}

// MARK: - Preview

#Preview {
    CertificateGuideView()
}
