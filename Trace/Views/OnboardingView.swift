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

    private let totalPages = 5

    var body: some View {
        ZStack {
            TabView(selection: $currentPage.animation(.easeInOut)) {
                OnboardingPageView(
                    icon: "network",
                    title: "Welcome to Trace",
                    description: "A powerful network debugging tool that captures and analyzes HTTP/HTTPS traffic from your device",
                    iconColor: DesignSystem.Colors.accent
                )
                .tag(0)

                NotificationSetupPageView()
                    .tag(1)

                OnboardingPageView(
                    icon: "shield.checkered",
                    title: "Install Certificate",
                    description: "To capture HTTPS traffic, you need to install and trust our certificate. This is required for SSL/TLS decryption.",
                    iconColor: DesignSystem.Colors.success,
                    actionLabel: isCertificateTrusted ? nil : "Install Certificate",
                    action: {
                        showingCertificateGuide = true
                    },
                    statusLabel: isCertificateTrusted ? "Certificate Trusted" : nil,
                    statusSystemImage: isCertificateTrusted ? "checkmark.circle.fill" : nil,
                    statusColor: isCertificateTrusted ? DesignSystem.Colors.success : nil
                )
                .tag(2)

                VPNSetupPageView(
                    vpnManager: vpnManager,
                    setupComplete: $vpnSetupComplete,
                    setupError: $vpnSetupError
                )
                .tag(3)

                FeaturesPageView {
                    completeOnboarding()
                }
                .tag(4)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack {
                HStack {
                    Spacer()
                    if currentPage < totalPages - 1 {
                        Button("Skip") {
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
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
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

// MARK: - Notification Setup Page

struct NotificationSetupPageView: View {
    @State private var notificationStatus: NotificationStatus = .notDetermined
    @State private var isRequesting = false

    enum NotificationStatus {
        case notDetermined
        case authorized
        case denied
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()

            Image(systemName: statusIcon)
                .font(.system(size: DesignSystem.IconSize.hero))
                .foregroundStyle(statusColor)
                .traceBounceSymbolEffectIfAvailable()
                .padding(.bottom, DesignSystem.Spacing.lg)

            Text("Enable Notifications")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Get notified when capture events occur, requests are blocked, or when important updates are available.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .fixedSize(horizontal: false, vertical: true)

            // Status indicator
            if notificationStatus == .authorized {
                Label("Notifications Enabled", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(DesignSystem.Colors.success)
                    .padding(.top, DesignSystem.Spacing.md)
            } else if notificationStatus == .denied {
                Label("Notifications Disabled", systemImage: "bell.slash.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignSystem.Spacing.md)
            }

            // Action button
            if notificationStatus == .notDetermined {
                Button {
                    requestNotificationPermission()
                } label: {
                    if isRequesting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Enable Notifications")
                            .frame(maxWidth: .infinity)
                    }
                }
                .primaryActionButton(tint: DesignSystem.Colors.accent)
                .padding(.horizontal, DesignSystem.Spacing.xxxl)
                .padding(.top, DesignSystem.Spacing.lg)
                .disabled(isRequesting)

                Button("Maybe Later") {
                    notificationStatus = .denied
                }
                .foregroundStyle(.secondary)
                .padding(.top, DesignSystem.Spacing.sm)
            } else if notificationStatus == .denied {
                Text("You can enable notifications later in Settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, DesignSystem.Spacing.sm)
            }

            Spacer()
            Spacer()
        }
        .padding()
        .onAppear {
            Task {
                await refreshNotificationStatus()
            }
        }
    }

    private var statusIcon: String {
        switch notificationStatus {
        case .notDetermined:
            "bell.badge"
        case .authorized:
            "bell.badge.fill"
        case .denied:
            "bell.slash"
        }
    }

    private var statusColor: Color {
        switch notificationStatus {
        case .notDetermined:
            DesignSystem.Colors.accent
        case .authorized:
            DesignSystem.Colors.success
        case .denied:
            .secondary
        }
    }

    private func requestNotificationPermission() {
        isRequesting = true
        Task {
            do {
                try await NotificationManager.shared.requestAuthorization()
            } catch {
                CoreLog.lifecycle.warning(
                    "event=app.notification_permission outcome=failure error=\(error.localizedDescription, privacy: .public)"
                )
            }
            await refreshNotificationStatus()
            await MainActor.run {
                isRequesting = false
            }
        }
    }

    private func refreshNotificationStatus() async {
        let status = await NotificationManager.shared.checkAuthorizationStatus()
        await MainActor.run {
            switch status {
            case .authorized, .provisional, .ephemeral:
                notificationStatus = .authorized
            case .denied:
                notificationStatus = .denied
            case .notDetermined:
                notificationStatus = .notDetermined
            @unknown default:
                notificationStatus = .notDetermined
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
            if vpnManager.isSimulator {
                Label("VPN not available in Simulator", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, DesignSystem.Spacing.md)
            } else if setupComplete || vpnManager.status != .invalid {
                Label("VPN Configuration Added", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(DesignSystem.Colors.success)
                    .padding(.top, DesignSystem.Spacing.md)
            } else if let error = setupError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(DesignSystem.Colors.danger)
                    .padding(.top, DesignSystem.Spacing.md)
            }

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
                setupComplete = true
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
                    setupComplete = true
                    setupError = nil
                }
            } catch {
                await MainActor.run {
                    setupError = error.localizedDescription
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
