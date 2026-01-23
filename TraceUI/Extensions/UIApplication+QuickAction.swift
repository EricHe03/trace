//
//  UIApplication+QuickAction.swift
//  TraceUI
//
//  Created by Justin on 2026/01/10.
//

import UIKit

public extension UIApplication {
    private static var shortcutItemKey: UInt8 = 0

    /// Returns the shortcut item selected by the user, if any.
    var shortcutItem: UIApplicationShortcutItem? {
        get {
            objc_getAssociatedObject(self, &UIApplication.shortcutItemKey) as? UIApplicationShortcutItem
        }
        set {
            objc_setAssociatedObject(self, &UIApplication.shortcutItemKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
