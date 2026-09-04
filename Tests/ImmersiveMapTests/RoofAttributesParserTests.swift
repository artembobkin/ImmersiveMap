// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

final class RoofAttributesParserTests: XCTestCase {
    private func stringValue(_ string: String) -> MvtValue {
        .string(string)
    }

    private func doubleValue(_ double: Double) -> MvtValue {
        .double(double)
    }

    private func numericParser(_ value: MvtValue) -> Float? {
        switch value {
        case .double(let number): return Float(number)
        case .string(let text): return Float(text)
        default: return nil
        }
    }

    private func parse(_ attributes: [String: MvtValue]) -> RoofInfo? {
        RoofAttributesParser().parse(attributes: attributes, numericParser: numericParser)
    }

    func testParsesOrientationAndNumericDirection() throws {
        let roof = try XCTUnwrap(parse([
            "roof:shape": stringValue("gabled"),
            "roof:height": doubleValue(4),
            "roof:orientation": stringValue("across"),
            "roof:direction": doubleValue(135)
        ]))
        XCTAssertEqual(roof.shape, .gabled)
        XCTAssertEqual(roof.orientation, .across)
        XCTAssertEqual(try XCTUnwrap(roof.directionDegrees), 135, accuracy: 0.001)
    }

    func testParsesCompassPointDirection() throws {
        let roof = try XCTUnwrap(parse([
            "roof:shape": stringValue("skillion"),
            "roof:height": doubleValue(2),
            "roof:direction": stringValue("SE")
        ]))
        XCTAssertEqual(try XCTUnwrap(roof.directionDegrees), 135, accuracy: 0.001)
    }

    func testAbsentTagsLeaveOrientationAndDirectionNil() throws {
        let roof = try XCTUnwrap(parse([
            "roof:shape": stringValue("hipped"),
            "roof:height": doubleValue(3)
        ]))
        XCTAssertNil(roof.orientation)
        XCTAssertNil(roof.directionDegrees)
    }

    func testMapsShapeAliasesOntoBuildableShapes() throws {
        let cases: [(String, RoofShape)] = [
            ("gambrel", .gabled),
            ("mansard", .hipped),
            ("half-dome", .dome),
            ("onion", .dome),
            ("pyramidal", .pyramid)
        ]
        for (raw, expected) in cases {
            let roof = try XCTUnwrap(parse([
                "roof:shape": stringValue(raw),
                "roof:height": doubleValue(2)
            ]), "\(raw) should parse")
            XCTAssertEqual(roof.shape, expected, "\(raw)")
        }
    }
}
