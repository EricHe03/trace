//
//  CustomActivities.swift
//  Trace
//
//  Created by Justin on 2026/01/10.
//

import TraceUI
import UIKit

// MARK: - Copy as cURL Activity

class CopyAsCurlActivity: UIActivity {
    private var curlCommand: String?

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.trace.copyAsCurl")
    }

    override var activityTitle: String? {
        "Copy as cURL"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "terminal")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { item in
            if let string = item as? String {
                return string.hasPrefix("curl")
            }
            return false
        }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        curlCommand = activityItems.compactMap { $0 as? String }.first { $0.hasPrefix("curl") }
    }

    override func perform() {
        if let curlCommand {
            UIPasteboard.general.string = curlCommand
            DesignSystem.Haptics.light()
        }
        activityDidFinish(curlCommand != nil)
    }
}

// MARK: - Copy URL Activity

class CopyURLActivity: UIActivity {
    private var url: String?

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.trace.copyURL")
    }

    override var activityTitle: String? {
        "Copy URL"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "doc.on.doc")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { $0 is URL || ($0 as? String)?.starts(with: "http") == true }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if let urlItem = activityItems.first(where: { $0 is URL }) as? URL {
            url = urlItem.absoluteString
        } else if let stringURL = activityItems.first(where: { ($0 as? String)?.starts(with: "http") == true }) as? String {
            url = stringURL
        }
    }

    override func perform() {
        if let url {
            UIPasteboard.general.string = url
            DesignSystem.Haptics.light()
        }
        activityDidFinish(url != nil)
    }
}

// MARK: - Export as HAR Activity

class ExportAsHARActivity: UIActivity {
    var harExportHandler: (() -> Void)?

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.trace.exportAsHAR")
    }

    override var activityTitle: String? {
        "Export as HAR"
    }

    override var activityImage: UIImage? {
        UIImage(systemName: "doc.badge.arrow.up")
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        // Rule: Only show this activity when a handler is provided.
        harExportHandler != nil
    }

    override func prepare(withActivityItems activityItems: [Any]) {}

    override func perform() {
        harExportHandler?()
        activityDidFinish(true)
    }
}

// MARK: - Activity Helper

enum ActivityHelper {
    /// Returns the default excluded activity types for the Trace app.
    /// - Returns: The activity types to exclude from share sheets.
    static func defaultExcludedActivityTypes() -> [UIActivity.ActivityType] {
        [
            // Rule: Exclude social sharing because it is not relevant for network debugging.
            .postToFacebook,
            .postToTwitter,
            .postToWeibo,
            .postToVimeo,
            .postToFlickr,
            .postToTencentWeibo,

            // Rule: Exclude contact management flows for request sharing.
            .assignToContact,

            // Rule: Exclude reading/media apps to keep exports focused on raw data.
            .addToReadingList,
            .openInIBooks,

            // Rule: Prefer raw data export over markup workflows.
            .markupAsPDF
        ]
    }

    /// Returns app-specific custom activities.
    /// - Returns: Custom activities for request sharing.
    static func customActivitiesForRequest() -> [UIActivity] {
        [
            CopyAsCurlActivity(),
            CopyURLActivity()
        ]
    }

    /// Returns custom activities for HAR export.
    /// - Parameter harHandler: The handler to run when the HAR export activity is selected.
    /// - Returns: Custom activities for HAR export.
    static func customActivitiesWithHAR(harHandler: @escaping () -> Void) -> [UIActivity] {
        let harActivity = ExportAsHARActivity()
        harActivity.harExportHandler = harHandler
        return [
            CopyAsCurlActivity(),
            CopyURLActivity(),
            harActivity
        ]
    }
}
