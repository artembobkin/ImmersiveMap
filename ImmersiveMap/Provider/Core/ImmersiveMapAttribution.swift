// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Атрибуция источника данных карты: то, что обязан показать продукт, использующий
/// чужие тайлы. Принадлежит провайдеру, а не движку: тайлы приносит провайдер, значит
/// он же знает, чьи это данные и под какой лицензией они отданы.
///
/// Движок никогда не подставляет сюда собственный бренд: карта, нарисованная поверх
/// данных OpenStreetMap, обязана называть OpenStreetMap, а не рендерер.
public struct ImmersiveMapAttribution: Equatable, Sendable {
    /// Первая строка бейджа: источник тайлов.
    public var title: String

    /// Вторая строка бейджа: копирайты данных.
    public var copyright: String

    /// Куда ведет тап по бейджу. Обычно страница лицензии источника данных.
    public var linkURL: URL?

    public var isEmpty: Bool {
        title.isEmpty && copyright.isEmpty
    }

    public init(title: String, copyright: String, linkURL: URL? = nil) {
        self.title = title
        self.copyright = copyright
        self.linkURL = linkURL
    }

    /// Пустая атрибуция: бейдж ничего не рисует. Значение по умолчанию для провайдеров,
    /// чей источник данных движку неизвестен. Если такой провайдер отдает данные OSM или
    /// другие данные с требованием атрибуции, ее обязан задать автор провайдера.
    public static let none = ImmersiveMapAttribution(title: "", copyright: "")

    /// Минимальная атрибуция для данных OpenStreetMap (ODbL).
    public static let openStreetMap = ImmersiveMapAttribution(
        title: "© OpenStreetMap",
        copyright: "OpenStreetMap contributors",
        linkURL: URL(string: "https://www.openstreetmap.org/copyright")
    )
}
