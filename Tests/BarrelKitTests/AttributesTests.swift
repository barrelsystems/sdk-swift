import Testing

@testable import BarrelKit

@Suite struct AttributesTests {
  @Test func passesThroughAttributesWithinBoundsUnchanged() {
    #expect(boundAttributes(["tier": "pro", "seat": "42"]) == ["tier": "pro", "seat": "42"])
  }

  @Test func keepsOnlyTheFirstTwentyKeys() {
    let attributes = Dictionary(uniqueKeysWithValues: (0..<25).map { ("key\($0)", "v") })
    #expect(boundAttributes(attributes).count == 20)
  }

  @Test func truncatesAValueOverTwoHundredFiftySixBytesWithoutSplittingAMultiByteCharacter() {
    let value = String(repeating: "é", count: 200)  // 2 bytes each in UTF-8, 400 bytes total
    let result = boundAttributes(["key": value])["key"] ?? ""
    #expect(result.utf8.count <= 256)
    #expect(!result.contains("\u{FFFD}"))
  }
  @Test func neverSubstitutesReplacementTextForATruncatedFourByteCharacter() {
    let value = "x" + String(repeating: "😀", count: 80)
    let result = boundAttributes(["key": value])["key"] ?? ""
    #expect(result.utf8.count <= 256)
    #expect(!result.contains("\u{FFFD}"))
    #expect(value.hasPrefix(result))
  }

}
