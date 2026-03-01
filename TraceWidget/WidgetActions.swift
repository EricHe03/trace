//
//  WidgetActions.swift
//  TraceWidget
//
//  Created by Justin on 2026/01/14.
//

import Foundation
import TraceCore

/// Records a widget action in shared App Group storage for the app to process.
///
/// The action is stored in shared storage so the app can detect and respond to
/// widget interactions when launched.
///
/// - Parameters:
///   - action: The action to record.
///   - view: Optional target view to open in the app.
func recordWidgetAction(_ action: WidgetAction, view: TraceAppView? = nil) {
    let pending = WidgetPendingAction(action: action, actionDate: Date(), actionView: view?.rawValue)
    try? AppGroupStorage.shared.saveWidgetPendingAction(pending)
}
