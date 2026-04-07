//
//  OnboardingView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import NetworkExtension
import os
import SwiftUI
import TraceCore
import TraceFeatures
import TraceSecurity
import TraceUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var showingCertificateGuide = false
    @State private var vpnSetupComplete = false
    @State private var vpnSetupError: String?
    @State private var isCertificateTrusted = false
    @ObservedObject private var vpnManager = VPNManager.shared
    var onComplete: () -> Void

    private let totalPages = 4

    var body: some View {
        ZStack {
            TabView(selection: $currentPage.animation(.easeInOut)) {
                OnboardingPageView(
                    icon: "network",
                    title: "Welcome to Trace",
                    description: "Capture and inspect HTTP and HTTPS traffic directly on your device.",
                    iconColor: DesignSystem.Colors.accent
                )
                .tag(0)

                OnboardingPageView(
                    icon: "shield.checkered",
                    title: "Install Certificate",
                    description: "To inspect HTTPS payloads, install and trust the Trace certificate. You can do this now or later in Settings.",
                    iconColor: DesignSystem.Colors.success,
                    actionLabel: isCertificateTrusted ? nil : "Install Certificate",
                    action: {
                        showingCertificateGuide = true
                    },
                    statusLabel: isCertificateTrusted ? "Certificate Trusted" : nil,
                    statusSystemImage: isCertificateTrusted ? "checkmark.circle.fill" : nil,
                    statusColor: isCertificateTrusted ? DesignSystem.Colors.success : nil
                )
                .tag(1)

                VPNSetupPageView(
                    vpnManager: vpnManager,
                    setupComplete: $vpnSetupComplete,
                    setupError: $vpnSetupError
                )
                .tag(2)

                FeaturesPageView {
                    completeOnboarding()
                }
                .tag(3)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack {
                HStack {
                    Spacer()
                    if currentPage < totalPages - 1 {
                        Button("Skip Setup") {
                            completeOnboarding()
                        }
                        .foregroundStyle(.secondary)
                        .padding()
                    }
                }
                Spacer()
            }
        }
        .sheet(isPresented: $showingCertificateGuide) {
            NavigationStack {
                CertificateGuideView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                showingCertificateGuide = false
                            }
                        }
                    }
            }
        }
        .onAppear {
            refreshCertificateTrustStatus()
        }
        .onChangeCompat(of: showingCertificateGuide) { isShowing in
            if !isShowing {
                refreshCertificateTrustStatus()
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: TraceUserDefaultsKey.hasCompletedOnboarding)
        NotificationCenter.default.post(name: .onboardingCompleted, object: nil)
        onComplete()
        dismiss()
    }

    private func refreshCertificateTrustStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let trusted = CertificateManager.shared.isRootCATrusted()
            DispatchQueue.main.async {
                isCertificateTrusted = trusted
            }
        }
    }
}

struct OnboardingPageView: View {
    let icon: String
    let title: String
    let description: String
    var iconColor: Color = DesignSystem.Colors.accent
    var actionLabel: String?
    var action: (() -> Void)?
    var statusLabel: String?
    var statusSystemImage: String?
    var statusColor: Color?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(iconColor)
                .traceBounceSymbolEffectIfAvailable()
                .padding(.bottom, DesignSystem.Spacing.lg)

            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .fixedSize(horizontal: false, vertical: true)

            if let statusLabel {
                Label(statusLabel, systemImage: statusSystemImage ?? "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(statusColor ?? DesignSystem.Colors.success)
                    .padding(.top, DesignSystem.Spacing.md)
            }

            if let actionLabel, let action {
                Button(action: action) {
                    Text(actionLabel)
                        .frame(maxWidth: .infinity)
                }
                .primaryActionButton(tint: iconColor)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .padding(.top, DesignSystem.Spacing.lg)
            }

            Spacer()
            Spacer()
        }
        .padding()
    }
}

// MARK: - Features Page (Apple HIG: Icon + Text pairs)

struct FeaturesPageView: View {
    var action: () -> Void

    private let features: [(icon: String, title: String, color: Color)] = [
        ("network", "HTTP/HTTPS Capture", DesignSystem.Colors.accent),
        ("message.badge.waveform", "WebSocket Monitoring", DesignSystem.Colors.accentAlt),
        ("arrow.triangle.2.circlepath", "Request Replay", DesignSystem.Colors.success),
        ("pencil.and.outline", "Traffic Rewriting", DesignSystem.Colors.warning),
        ("square.and.arrow.up", "Export to HAR", DesignSystem.Colors.info),
        ("wrench.and.screwdriver", "Built-in Utilities", DesignSystem.Colors.muted)
    ]

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Spacer()

            Image(systemName: "star.fill")
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(DesignSystem.Colors.warning)
                .traceBounceSymbolEffectIfAvailable()
                .padding(.bottom, DesignSystem.Spacing.md)
                .accessibilityHidden(true)

            Text("Powerful Features")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Everything you need for network debugging")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)

            // Feature grid using icon + text pairs (Apple HIG pattern)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DesignSystem.Spacing.lg) {
                ForEach(features, id: \.title) { feature in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: feature.icon)
                            .font(.body)
                            .foregroundStyle(feature.color)
                            .frame(width: 24)
                        Text(feature.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.top, DesignSystem.Spacing.md)

            Button(action: action) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .primaryActionButton(tint: DesignSystem.Colors.warning)
            .padding(.horizontal, DesignSystem.Spacing.xxxl)
            .padding(.top, DesignSystem.Spacing.lg)

            Spacer()
            Spacer()
        }
        .padding()
    }
}

// MARK: - VPN Setup Page

struct VPNSetupPageView: View {
    @ObservedObject var vpnManager: VPNManager
    @Binding var setupComplete: Bool
    @Binding var setupError: String?

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            Image(systemName: vpnStatusIcon)
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(vpnStatusColor)
                .traceBounceSymbolEffectIfAvailable()
                .animation(DesignSystem.Accessibility.springAnimation, value: vpnStatusIcon)
                .padding(.bottom, DesignSystem.Spacing.lg)

            Text("Enable VPN")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Trace uses a local VPN to capture traffic. Your data never leaves your device and is processed entirely on-device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .fixedSize(horizontal: false, vertical: true)

            // Status indicator
            Group {
                if vpnManager.isSimulator {
                    Label("VPN not available in Simulator", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                } else if setupComplete || vpnManager.status != .invalid {
                    Label("VPN Configuration Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if let error = setupError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.danger)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.headline)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.horizontal, DesignSystem.Spacing.xxxl)
            .transition(DesignSystem.Accessibility.transition(standard: .opacity.combined(with: .scale(scale: 0.95))))

            // Enable VPN button
            if !vpnManager.isSimulator && !setupComplete && vpnManager.status == .invalid {
                Button {
                    enableVPN()
                } label: {
                    Text("Enable VPN")
                        .frame(maxWidth: .infinity)
                }
                .primaryActionButton(tint: DesignSystem.Colors.accentAlt)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .padding(.top, DesignSystem.Spacing.lg)
            }

            Spacer()
            Spacer()
        }
        .padding()
        .onAppear {
            // Only load existing VPN configuration (if any) when user reaches this page
            // This does NOT trigger the permission popup - that happens when user taps "Enable VPN"
            vpnManager.initializeIfNeeded()
        }
        .onReceive(vpnManager.$status) { status in
            if status != .invalid {
                withAnimation(DesignSystem.Accessibility.springAnimation) {
                    setupComplete = true
                }
            }
        }
    }

    private var vpnStatusIcon: String {
        if vpnManager.isSimulator {
            "xmark.shield.fill"
        } else if setupComplete || vpnManager.status != .invalid {
            "checkmark.shield.fill"
        } else {
            "network.badge.shield.half.filled"
        }
    }

    private var vpnStatusColor: Color {
        if vpnManager.isSimulator {
            .orange
        } else if setupComplete || vpnManager.status != .invalid {
            DesignSystem.Colors.success
        } else {
            DesignSystem.Colors.accentAlt
        }
    }

    private func enableVPN() {
        Task {
            do {
                // This will trigger the system prompt "Would Like to Add VPN Configurations"
                try await vpnManager.requestVPNPermission()
                await MainActor.run {
                    withAnimation(DesignSystem.Accessibility.springAnimation) {
                        setupComplete = true
                        setupError = nil
                    }
                    DesignSystem.Haptics.success()
                }
            } catch {
                await MainActor.run {
                    withAnimation(DesignSystem.Accessibility.springAnimation) {
                        setupError = error.localizedDescription
                    }
                    DesignSystem.Haptics.error()
                }
            }
        }
    }
}

#Preview {
    OnboardingView {
        CoreLog.lifecycle.info("event=app.onboarding outcome=completed")
    }
}
