// Run from the repository root: swift Scripts/update-traditional.swift
// Traditional Chinese uses the Simplified Chinese wording, converted by script only.
import Foundation
let base = URL(fileURLWithPath: "Sources/ThermalForgeLocalization/Resources")
let simplified = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: base.appendingPathComponent("zh-Hans.json")))
let traditional = try simplified.mapValues { value in
    guard let result = value.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false) else { throw CocoaError(.coderInvalidValue) }
    return result
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var data = try encoder.encode(traditional)
data.append(0x0a)
try data.write(to: base.appendingPathComponent("zh-Hant.json"))
