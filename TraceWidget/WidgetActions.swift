//
//  WidgetActions.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/14.
//

import Foundation
import TraceCore

/// Records a widget action in shared UserDefaults for the app to process.
///
/// The action is stored in the App Group container so the app can detect and
/// respond to widget interactions when launched.
///
/// - Parameters:
///   - action: The action to record.
///   - view: Optional target view to open in the app.
func recordWidgetAction(_ action: WidgetAction, view: TraceAppView? = nil) {
    let appGroupIdentifier = AppGroupConfiguration.appGroupIdentifier
    guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
        return
    }

    defaults.set(action.rawValue, forKey: WidgetActionKey.action)
    defaults.set(Date(), forKey: WidgetActionKey.actionDate)
    if let view {
        defaults.set(view.rawValue, forKey: WidgetActionKey.actionView)
    } else {
        defaults.removeObject(forKey: WidgetActionKey.actionView)
    }
}
