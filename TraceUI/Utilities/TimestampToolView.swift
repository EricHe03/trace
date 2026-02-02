//
//  TimestampToolView.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import SwiftUI

/// Presents a timestamp conversion tool for Unix and ISO 8601 formats.
public struct TimestampToolView: View {
    @State private var unixTimestamp = ""
    @State private var isoDateTime = ""
    @State private var timestampUnit: TimestampUnit = .seconds
    @State private var selectedTimezone = TimeZone.current
    @State private var toastMessage: String?

    public init() {}

    enum TimestampUnit: String, CaseIterable {
        case seconds = "Seconds"
        case milliseconds = "Milliseconds"
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    public var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.lgPlus) {
                VStack(spacing: DesignSystem.Spacing.md) {
                    Button {
                        setCurrentTime()
                    } label: {
                        Label("Set to Current Time", systemImage: "clock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Set to current time")
                    .accessibilityHint("Double tap to set fields to the current date and time")
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("Unix Timestamp")
                            .font(.headline)

                        Spacer()

                        Button {
                            copyToClipboard(unixTimestamp)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .disabled(unixTimestamp.isEmpty)
                    }

                    HStack {
                        TextField("Enter timestamp", text: $unixTimestamp)
                            .keyboardType(.numberPad)
                            .padding(DesignSystem.Spacing.md)
                            .background(DesignSystem.Colors.surfaceMuted)
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.md))
                            .font(.system(.body, design: .monospaced))
                            .onChangeCompat(of: unixTimestamp) { newValue in
                                timestampToDate(newValue)
                            }

                        Picker("Unit", selection: $timestampUnit) {
                            ForEach(TimestampUnit.allCases, id: \.self) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChangeCompat(of: timestampUnit) {
                            timestampToDate(unixTimestamp)
                        }
                    }

                    Text("Unix time (epoch time) in \(timestampUnit.rawValue.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text("ISO 8601 DateTime")
                            .font(.headline)

                        Spacer()

                        Button {
                            copyToClipboard(isoDateTime)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .disabled(isoDateTime.isEmpty)
                    }

                    TextEditor(text: $isoDateTime)
                        .frame(height: 80)
                        .font(DesignSystem.Typography.monospacedFont)
                        .formTextEditorStyle()
                        .onChangeCompat(of: isoDateTime) { newValue in
                            dateToTimestamp(newValue)
                        }

                    Text("ISO 8601 format: 2024-01-15T10:30:00.000+0000")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Timezone")
                        .font(.headline)

                    HStack {
                        Picker("Timezone", selection: $selectedTimezone) {
                            ForEach(commonTimezones, id: \.identifier) { timezone in
                                Text("\(timezone.identifier) (\(timezone.abbreviation() ?? ""))")
                                    .tag(timezone)
                            }
                        }
                        .onChangeCompat(of: selectedTimezone) {
                            dateFormatter.timeZone = selectedTimezone
                            timestampToDate(unixTimestamp)
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal)

                if let timestamp = Double(unixTimestamp),
                   let date = timestampToDate(timestamp) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Human Readable")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            InfoRowHorizontal(label: "Date", value: formatDate(date, format: "MMMM d, yyyy"))
                            InfoRowHorizontal(label: "Time", value: formatDate(date, format: "HH:mm:ss"))
                            InfoRowHorizontal(label: "Weekday", value: formatDate(date, format: "EEEE"))
                            InfoRowHorizontal(label: "Relative", value: date.formatted(.relative(presentation: .named)))
                        }
                        .padding()
                        .background(DesignSystem.Colors.surfaceMuted)
                        .cornerRadius(DesignSystem.CornerRadius.md)
                    }
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
        }
        .toast(message: $toastMessage)
        .dismissKeyboardOnTapAndScroll()
        .navigationTitle("Timestamp")
        .onAppear {
            dateFormatter.timeZone = selectedTimezone
        }
    }

    private var commonTimezones: [TimeZone] {
        var timezones = [
            TimeZone(identifier: "UTC")!,
            TimeZone(identifier: "America/New_York")!,
            TimeZone(identifier: "America/Los_Angeles")!,
            TimeZone(identifier: "Europe/London")!,
            TimeZone(identifier: "Europe/Paris")!,
            TimeZone(identifier: "Asia/Tokyo")!,
            TimeZone(identifier: "Asia/Shanghai")!
        ]

        // Rule: Ensure the current timezone is available in the picker.
        let current = TimeZone.current
        if !timezones.contains(where: { $0.identifier == current.identifier }) {
            timezones.insert(current, at: 0)
        }

        return timezones
    }

    private func setCurrentTime() {
        let now = Date()
        let timestamp: Double = switch timestampUnit {
        case .seconds:
            now.timeIntervalSince1970
        case .milliseconds:
            now.timeIntervalSince1970 * 1000
        }

        unixTimestamp = String(format: "%.0f", timestamp)
        dateFormatter.timeZone = selectedTimezone
        isoDateTime = dateFormatter.string(from: now)
    }

    private func timestampToDate(_ timestampString: String) {
        guard let timestamp = Double(timestampString) else {
            isoDateTime = ""
            return
        }

        guard let date = timestampToDate(timestamp) else {
            isoDateTime = ""
            return
        }

        dateFormatter.timeZone = selectedTimezone
        isoDateTime = dateFormatter.string(from: date)
    }

    private func timestampToDate(_ timestamp: Double) -> Date? {
        let timeInterval: TimeInterval = switch timestampUnit {
        case .seconds:
            timestamp
        case .milliseconds:
            timestamp / 1000
        }

        return Date(timeIntervalSince1970: timeInterval)
    }

    private func dateToTimestamp(_ dateString: String) {
        dateFormatter.timeZone = selectedTimezone

        guard let date = dateFormatter.date(from: dateString) else {
            return
        }

        let timestamp: Double = switch timestampUnit {
        case .seconds:
            date.timeIntervalSince1970
        case .milliseconds:
            date.timeIntervalSince1970 * 1000
        }

        unixTimestamp = String(format: "%.0f", timestamp)
    }

    private func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = selectedTimezone
        return formatter.string(from: date)
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        withAnimation(DesignSystem.Accessibility.preferredAnimation) {
            toastMessage = "Copied: \(String(text.prefix(20)))"
        }
    }
}

private struct InfoRowHorizontal: View {
    let label: String
    let value: String

    var body: some View {
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
}

#Preview {
    TimestampToolView()
}
