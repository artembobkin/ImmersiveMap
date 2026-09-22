// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

enum DebugOverlayDiagnosticsTextStyle: Equatable {
    case section(String)
    case key
    case warningValue
}

struct DebugOverlayDiagnosticsTextStyleRun: Equatable {
    let range: NSRange
    let style: DebugOverlayDiagnosticsTextStyle
}

enum DebugOverlayDiagnosticsTextStylePlanner {
    private static let keyExpression = try! NSRegularExpression(
        pattern: "(^| )([A-Za-z][A-Za-z0-9]*:)",
        options: []
    )

    static func makeRuns(for text: String) -> [DebugOverlayDiagnosticsTextStyleRun] {
        let lines = text.components(separatedBy: "\n")
        var runs: [DebugOverlayDiagnosticsTextStyleRun] = []
        var activeSection: String?
        var location = 0

        for line in lines {
            let lineLength = (line as NSString).length
            defer {
                location += lineLength + 1
            }

            guard line.isEmpty == false else {
                activeSection = nil
                continue
            }

            if let section = sectionTitle(from: line) {
                activeSection = section
                runs.append(DebugOverlayDiagnosticsTextStyleRun(
                    range: NSRange(location: location, length: lineLength),
                    style: .section(section)
                ))
                continue
            }

            if activeSection == "Skip", line != "none" {
                runs.append(DebugOverlayDiagnosticsTextStyleRun(
                    range: NSRange(location: location, length: lineLength),
                    style: .warningValue
                ))
            }

            appendKeyRuns(line: line, lineLocation: location, into: &runs)
        }

        return runs
    }

    private static func sectionTitle(from line: String) -> String? {
        guard line.first == "[", line.last == "]", line.count > 2 else {
            return nil
        }
        return String(line.dropFirst().dropLast())
    }

    private static func appendKeyRuns(line: String,
                                      lineLocation: Int,
                                      into runs: inout [DebugOverlayDiagnosticsTextStyleRun]) {
        let lineRange = NSRange(location: 0, length: (line as NSString).length)
        let matches = keyExpression.matches(in: line, options: [], range: lineRange)

        for match in matches {
            let keyRange = match.range(at: 2)
            runs.append(DebugOverlayDiagnosticsTextStyleRun(
                range: NSRange(location: lineLocation + keyRange.location, length: keyRange.length),
                style: .key
            ))
        }
    }
}
