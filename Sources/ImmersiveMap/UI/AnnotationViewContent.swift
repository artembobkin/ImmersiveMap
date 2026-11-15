// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import SwiftUI

/// One SwiftUI annotation after eager ViewBuilder evaluation in body:
/// the public Identifiable id, the coordinate, and the type-erased content.
/// Not Sendable (AnyView): lives only on the MainActor and travels along the chain
/// representable -> host view -> host runtime -> annotation runtime.
struct AnnotationViewItem {
    let id: AnyHashable
    let coordinate: GeoCoordinate
    let content: AnyView
    /// The element the annotation was made from, when the app's elements can
    /// be compared: a annotation whose element is what it was keeps its view
    /// untouched. Nil for elements that cannot be compared, whose view is
    /// handed to SwiftUI again on every update.
    let element: AnnotationElement?

    init(id: AnyHashable, coordinate: GeoCoordinate, content: AnyView, element: AnnotationElement? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.content = content
        self.element = element
    }

    /// Whether the annotation's view is certainly the one `previous` stands
    /// for: both were made from elements that compare equal.
    func hasSameContent(as previous: AnnotationElement?) -> Bool {
        guard let element, let previous else { return false }
        return element.isEqual(previous)
    }
}

/// An app's element behind a annotation, with its type erased and its `==`
/// kept.
struct AnnotationElement {
    private let value: Any
    private let equals: (Any) -> Bool

    init<Element: Equatable>(_ element: Element) {
        value = element
        equals = { ($0 as? Element) == element }
    }

    func isEqual(_ other: AnnotationElement) -> Bool {
        equals(other.value)
    }
}

/// A annotation's content as its hosting view holds it: at its own ideal
/// size, which it reports whenever SwiftUI lays it out anew. The map
/// places the view by that size and never has to measure it again.
struct AnnotationSizedContent: View {
    let content: AnyView
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
    }
}

/// Carries a annotation's size from its content to its host: the content's
/// closure stays the same across updates of the content, and the host says
/// where the size goes once it exists.
@MainActor
final class AnnotationSizeReport {
    var receive: ((CGSize) -> Void)?

    /// What the content calls: a closure value, made once.
    private(set) lazy var send: (CGSize) -> Void = { [weak self] size in
        self?.receive?(size)
    }
}

/// The full annotation set of one `.annotations(...)` call: a repeated call
/// replaces the previous set entirely.
struct AnnotationViewContent {
    let anchor: UnitPoint
    let items: [AnnotationViewItem]
}
