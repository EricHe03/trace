//
//  DirectionalScrollView.swift
//  TraceUI
//
//  Created by Justin on 2026/04/07.
//

import SwiftUI
import UIKit

/// A scroll view that locks to a single scroll axis once the drag direction is determined,
/// preventing diagonal scrolling. Wraps UIScrollView.isDirectionalLockEnabled.
public struct DirectionalScrollView<Content: View>: UIViewRepresentable {
    private let axes: Axis.Set
    private let content: Content

    public init(_ axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = axes.contains(.horizontal)
        scrollView.alwaysBounceVertical = axes.contains(.vertical)

        let hostingController = context.coordinator.hostingController
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor)
        ])

        if !axes.contains(.horizontal) {
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
        }
        if !axes.contains(.vertical) {
            hostingController.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor).isActive = true
        }

        return scrollView
    }

    public func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.hostingController.view.setNeedsLayout()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    @MainActor
    public final class Coordinator {
        let hostingController: UIHostingController<Content>

        init(content: Content) {
            hostingController = UIHostingController(rootView: content)
        }
    }
}
