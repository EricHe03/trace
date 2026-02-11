//
//  PrivacyPolicyView.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI
import TraceCore
import TraceUI

struct PrivacyPolicyView: View {
    var body: some View {
        List {
            // Header Section
            Section {
                VStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
                    // Privacy Shield Icon
                    Image(systemName: "hand.raised.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(DesignSystem.Colors.success)
                        .symbolRenderingMode(.hierarchical)

                    // Main Privacy Statement
                    Text("Your Privacy is Protected")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("All network traffic is captured and processed entirely on your device. Nothing ever leaves your device unless you choose to export/share it.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    // Key Privacy Badges
                    HStack(spacing: DesignSystem.Spacing.md) {
                        PrivacyBadge(icon: "iphone", text: "On-Device")
                        PrivacyBadge(icon: "xmark.icloud", text: "No Cloud")
                        PrivacyBadge(icon: "eye.slash", text: "No Tracking")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignSystem.Spacing.md)
            } footer: {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    Text("Effective Date: \(LegalConfig.privacyPolicyEffectiveDate)")
                    Text("Developer: Justin")
                    Text("Contact: epa6643@gmail.com")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .font(.caption)
            }

            // 1. Summary
            Section {
                PolicyRow(
                    icon: "doc.text.fill",
                    iconColor: DesignSystem.Colors.accent,
                    title: "Privacy Summary",
                    items: [
                        "We do not collect, transmit, sell, or share your personal data with us or any third parties",
                        "The App processes and stores network traffic data on your device only",
                        "Data may leave your device only if you choose to export/share it using iOS features (e.g., Share Sheet)"
                    ]
                )
            } header: {
                Text("1. Summary")
            }

            // 2. Definitions
            Section {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    DefinitionItem(
                        icon: "antenna.radiowaves.left.and.right",
                        iconColor: DesignSystem.Colors.info,
                        term: "Capture Data",
                        definition: "Any network traffic content and metadata the App displays or stores, including HTTP(S) requests and responses, WebSocket frames, Server-Sent Events (SSE) messages, headers, bodies, URLs, query parameters, cookies, tokens, timing, and TLS details."
                    )

                    DefinitionItem(
                        icon: "iphone.radiowaves.left.and.right",
                        iconColor: DesignSystem.Colors.success,
                        term: "On-Device",
                        definition: "Stored locally on your iPhone/iPad in the App's sandbox and/or App Group container shared with the App's extensions."
                    )
                }
            } header: {
                Text("2. Definitions")
            }

            // 3. Information the App Handles
            Section {
                PolicyRow(
                    icon: "network",
                    iconColor: DesignSystem.Colors.info,
                    title: "Capture Data (On-Device)",
                    description: "The App can capture and store network traffic that passes through a system proxy configured by the App's Network Extension. Depending on your device and usage, Capture Data may include highly sensitive information, such as:",
                    items: [
                        "Authentication tokens, API keys, session cookies",
                        "Personal messages or form inputs",
                        "Images, files, and other content in request/response bodies",
                        "Hostnames, URLs, and query strings that may reveal personal data"
                    ]
                )

                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text("Capture Data is created by your network activity and by apps/services you use. The App does not create this data; it enables you to view and manage it for debugging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("3.1 Capture Data")
            }

            // 3.2 TLS Decryption
            Section {
                PolicyRow(
                    icon: "lock.doc.fill",
                    iconColor: DesignSystem.Colors.accentAlt,
                    title: "TLS Decryption and Certificates",
                    description: "The App supports on-device TLS interception (\"TLS MITM\") for debugging. To do this, the App may generate a local root Certificate Authority (CA) and require you to install and trust it."
                )

                Text("If you enable TLS interception:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                PolicyRow(
                    icon: "checkmark.circle",
                    iconColor: DesignSystem.Colors.accent,
                    title: "",
                    items: [
                        "Encrypted HTTPS content may be decrypted and displayed on-device",
                        "Certificate material may be stored using iOS secure storage mechanisms (e.g., Keychain)"
                    ]
                )

                HStack(spacing: DesignSystem.Spacing.md) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(DesignSystem.Colors.info)
                    Text("You can disable TLS interception and remove the certificate by following the App's instructions and/or removing the certificate from iOS settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("3.2 TLS Decryption and Certificates")
            }

            // 3.3 App Data
            Section {
                PolicyRow(
                    icon: "folder.fill",
                    iconColor: DesignSystem.Colors.warning,
                    title: "App Data (On-Device)",
                    description: "The App stores configuration and operational data on-device, which may include:",
                    items: [
                        "Capture sessions and their organization",
                        "Filtering/search settings",
                        "Rewrite rules, scripts, breakpoints, request maps, host overrides, and presets",
                        "Import/export artifacts (e.g., HAR files) that you create or import",
                        "UI preferences and other local settings"
                    ]
                )

                Text("The App uses an iOS App Group container to share data between the main app and its extensions (e.g., network extension, widgets) where applicable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("3.3 App Data")
            }

            // 3.4 No Analytics
            Section {
                PolicyRow(
                    icon: "hand.raised.slash.fill",
                    iconColor: DesignSystem.Colors.danger,
                    title: "No Analytics, No Accounts, No Server-Side Processing",
                    description: "We do not:",
                    items: [
                        "Operate servers that receive your Capture Data or personal information",
                        "Collect analytics or telemetry",
                        "Use advertising SDKs",
                        "Use crash reporting services that transmit data to us or third parties",
                        "Require accounts or logins"
                    ]
                )
            } header: {
                Text("3.4 No Analytics or Server Processing")
            }

            // 4. How Information Is Used
            Section {
                PolicyRow(
                    icon: "gearshape.2.fill",
                    iconColor: DesignSystem.Colors.accent,
                    title: "How Information Is Used",
                    description: "The App handles information solely to provide its functionality, including:",
                    items: [
                        "Capturing and displaying network traffic for inspection and debugging",
                        "Enabling modification, replay, and export of traffic data",
                        "Storing your sessions and configuration locally so you can use the App"
                    ]
                )
            } header: {
                Text("4. How Information Is Used")
            }

            // 5. Data Sharing and Disclosure
            Section {
                PolicyRow(
                    icon: "lock.slash.fill",
                    iconColor: DesignSystem.Colors.success,
                    title: "No Sale or Sharing by Us",
                    description: "We do not sell, rent, share, or disclose your information to third parties because we do not collect it on our systems."
                )

                PolicyRow(
                    icon: "square.and.arrow.up",
                    iconColor: DesignSystem.Colors.info,
                    title: "User-Initiated Exports/Sharing",
                    description: "If you use export or sharing features (e.g., exporting HAR, copying cURL, saving files, sharing via iOS Share Sheet), you are directing data to a destination you choose (e.g., Files, AirDrop, email, messaging apps, third-party storage). That destination's privacy practices apply."
                )
            } header: {
                Text("5. Data Sharing and Disclosure")
            }

            // 6. Tracking
            Section {
                PolicyRow(
                    icon: "eye.slash.fill",
                    iconColor: DesignSystem.Colors.success,
                    title: "No Tracking",
                    description: "The App does not track you across apps or websites, and does not use advertising identifiers for tracking purposes."
                )
            } header: {
                Text("6. Tracking")
            }

            // 7. Data Retention
            Section {
                PolicyRow(
                    icon: "trash.fill",
                    iconColor: DesignSystem.Colors.danger,
                    title: "Data Retention",
                    description: "All data is stored on your device and retained until you delete it, which you can do by:",
                    items: [
                        "Deleting individual sessions or data within the App (where available)",
                        "Uninstalling the App (which removes local app storage)",
                        "Removing certificates you installed for TLS interception via iOS settings (if applicable)"
                    ]
                )
            } header: {
                Text("7. Data Retention")
            }

            // 8. Security
            Section {
                PolicyRow(
                    icon: "shield.fill",
                    iconColor: DesignSystem.Colors.accent,
                    title: "Security",
                    description: "We use reasonable safeguards consistent with an on-device iOS app, including relying on iOS security features such as app sandboxing and device encryption. However, no method of storage is 100% secure."
                )

                Text("You are responsible for:")
                    .font(.subheadline)
                    .fontWeight(.medium)

                PolicyRow(
                    icon: "person.fill.checkmark",
                    iconColor: DesignSystem.Colors.warning,
                    title: "",
                    items: [
                        "Securing access to your device (passcode/biometrics)",
                        "Exercising caution when capturing, viewing, or exporting sensitive data",
                        "Ensuring you only intercept traffic you are authorized to inspect"
                    ]
                )
            } header: {
                Text("8. Security")
            }

            // 9. Your Choices and Controls
            Section {
                PolicyRow(
                    icon: "slider.horizontal.3",
                    iconColor: DesignSystem.Colors.info,
                    title: "Your Choices and Controls",
                    description: "You can control the App's handling of information by:",
                    items: [
                        "Starting/stopping capture at any time",
                        "Disabling TLS interception (if enabled)",
                        "Deleting sessions and local data",
                        "Choosing whether to export/share and what to export/share"
                    ]
                )
            } header: {
                Text("9. Your Choices and Controls")
            }

            // 10. Legal Compliance and Authorized Use
            Section {
                PolicyRow(
                    icon: "scale.3d",
                    iconColor: DesignSystem.Colors.warning,
                    title: "Legal Compliance and Authorized Use",
                    description: "The App is intended for debugging and inspection of traffic that you are authorized to access and analyze. You agree not to use the App to intercept or monitor communications without proper authorization. You are solely responsible for compliance with applicable laws, regulations, and third-party terms."
                )
            } header: {
                Text("10. Legal Compliance and Authorized Use")
            }

            // 11. Children's Privacy
            Section {
                PolicyRow(
                    icon: "figure.child",
                    iconColor: DesignSystem.Colors.info,
                    title: "Children's Privacy",
                    description: "The App is not directed to children. We do not knowingly collect personal information from children. Because the App does not transmit data to us, we have no practical means to identify users' ages."
                )
            } header: {
                Text("11. Children's Privacy")
            }

            // 12. International Users
            Section {
                PolicyRow(
                    icon: "globe",
                    iconColor: DesignSystem.Colors.accent,
                    title: "International Users",
                    description: "The App processes data on-device. If you export/share data, it may be transmitted to services or recipients you choose, which may be located outside your country. You are responsible for your sharing choices."
                )
            } header: {
                Text("12. International Users")
            }

            // 13. Changes to This Policy
            Section {
                PolicyRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: DesignSystem.Colors.muted,
                    title: "Changes to This Policy",
                    description: "We may update this Privacy Policy from time to time. If we make changes, we will update the Effective Date above and publish the revised policy where it is made available (e.g., in the App listing or repository page)."
                )
            } header: {
                Text("13. Changes to This Policy")
            }

            // 14. Contact Us
            Section {
                PolicyRow(
                    icon: "envelope.fill",
                    iconColor: DesignSystem.Colors.accent,
                    title: "Contact Us",
                    description: "If you have questions about this Privacy Policy, contact:"
                )

                if let url = URL(string: "mailto:epa6643@gmail.com") {
                    Link(destination: url) {
                        Label("epa6643@gmail.com", systemImage: "envelope")
                    }
                }
            } header: {
                Text("14. Contact Us")
            }
        }
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Helper Views

private struct PrivacyBadge: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(DesignSystem.Colors.accent)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
    }
}

private struct PolicyRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var description: String?
    var items: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                if !title.isEmpty {
                    Text(title)
                        .font(.headline)
                }

                if let description {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                Text(item)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 4) // Slight indent for bullets
                }
            }
        }
        .padding(.vertical, DesignSystem.Spacing.xs)
    }
}

private struct DefinitionItem: View {
    let icon: String
    let iconColor: Color
    let term: String
    let definition: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(term)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(definition)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
