//
//  QuickLookPreviewController.swift
//  TraceUI
//
//  Created by Justin on 2026/01/28.
//

import QuickLook
import SwiftUI

public struct QuickLookPreviewController: UIViewControllerRepresentable {
    public let url: URL
    public let title: String?
    public let onDismiss: () -> Void

    public init(url: URL, title: String? = nil, onDismiss: @escaping () -> Void) {
        self.url = url
        self.title = title
        self.onDismiss = onDismiss
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(url: url, title: title, onDismiss: onDismiss)
    }

    public func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator

        previewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.didTapDone)
        )

        if let title {
            previewController.navigationItem.title = title
        }

        let nav = UINavigationController(rootViewController: previewController)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    public func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.title = title

        if let previewController = uiViewController.viewControllers.first as? QLPreviewController {
            previewController.reloadData()
            previewController.navigationItem.title = title
        }
    }

    public final class Coordinator: NSObject, QLPreviewControllerDataSource {
        fileprivate var url: URL
        fileprivate var title: String?
        private let onDismiss: () -> Void

        fileprivate init(url: URL, title: String?, onDismiss: @escaping () -> Void) {
            self.url = url
            self.title = title
            self.onDismiss = onDismiss
        }

        @objc fileprivate func didTapDone() {
            onDismiss()
        }

        public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            PreviewItem(url: url, title: title)
        }
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    private let previewURL: URL
    private let previewTitle: String?

    init(url: URL, title: String?) {
        self.previewURL = url
        self.previewTitle = title
        super.init()
    }

    var previewItemURL: URL? {
        previewURL
    }

    var previewItemTitle: String? {
        previewTitle
    }
}
