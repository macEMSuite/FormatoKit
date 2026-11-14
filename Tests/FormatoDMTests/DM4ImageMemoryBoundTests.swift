//
//  DM4ImageMemoryBoundTests.swift
//  A 2D DM image is bounded by what it takes in memory, and its Float32 read holds no second full-size copy
//  (macEMSuite/FormatoKit#109). Red before: the limit was on the stored bytes only, so an 8-bit image passed at a quarter
//  of its Float32 size; and `readImage` held the stored bytes twice and the Float32 image at once.
//

import Foundation
import Testing
import FormatoCore
import FormatoDM

@Suite struct DM4ImageMemoryBoundTests {

    private static func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    private static func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    private static func head(_ tag: UInt8, _ label: String) -> [UInt8] { [tag] + be(UInt64(label.utf8.count), 2) + Array(label.utf8) + be(0, 8) }
    private static let delim: [UInt8] = [37, 37, 37, 37]
    private static func group(_ label: String, _ kids: [[UInt8]]) -> [UInt8] { head(20, label) + [1, 0] + be(UInt64(kids.count), 8) + kids.flatMap { $0 } }
    private static func int(_ label: String, _ v: Int32) -> [UInt8] {
        head(21, label) + delim + be(1, 8) + be(3, 8) + le(UInt64(UInt32(bitPattern: v)), 4)
    }

    /// A DM4 file with one 2D image object of `dataType` (DM codes), `width` x `height`, whose stored bytes are `blob`
    /// (array element type `elementType`, `count` elements).
    private static func file(dataType: Int32, width: Int32, height: Int32, elementType: UInt64, count: Int, blob: [UInt8]) -> Data {
        let data = head(21, "Data") + delim + be(3, 8) + be(20, 8) + be(elementType, 8) + be(UInt64(count), 8) + blob
        let object = group("", [
            group("ImageData", [data, int("DataType", dataType), group("Dimensions", [int("", width), int("", height)])]),
            group("ImageTags", []),
        ])
        let body: [UInt8] = [1, 0] + be(1, 8) + group("ImageList", [object])
        return Data(be(4, 4) + be(0, 8) + be(1, 4) + body)
    }

    @Test func anImageIsRefusedWhenItsFloat32CopyPassesTheLimitNotOnlyItsStoredBytes() throws {
        // 4 x 4 uint8: 16 stored bytes, 64 bytes as Float32. A limit of 32 bytes takes the stored image, not the Float32 one.
        let data = Self.file(dataType: 6, width: 4, height: 4, elementType: 8, count: 16, blob: (0..<16).map(UInt8.init))
        let stored = try DM4Experiment.readStoredImage(data: data, index: 1, maxBytes: 32)
        #expect(stored.pixels.bytes == Data((0..<16).map(UInt8.init)))
        #expect(throws: DM4Error.self) { _ = try DM4Experiment.readImage(data: data, index: 1, maxBytes: 32, blockBytes: 1 << 24) }
        #expect(try DM4Experiment.readImage(data: data, index: 1, maxBytes: 64, blockBytes: 1 << 24).pixels == (0..<16).map(Float.init))
    }

    @Test func theFloat32ReadConvertsBlockByBlockAndGivesEveryValue() throws {
        // 5 x 3 int16, read 3 bytes at a time: one value a block, so every block boundary is crossed, and a negative value.
        let values: [Int16] = [-7, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 32767]
        let blob = values.flatMap { Self.le(UInt64(UInt16(bitPattern: $0)), 2) }
        let data = Self.file(dataType: 1, width: 5, height: 3, elementType: 2, count: values.count, blob: blob)
        let whole = try DM4Experiment.readImage(data: data, index: 1)
        #expect(whole.pixels == values.map(Float.init))
        #expect(whole.width == 5 && whole.height == 3)
        for block in [1, 3, 4, 7, 30] {
            let image = try DM4Experiment.readImage(data: data, index: 1, maxBytes: 1 << 30, blockBytes: block)
            #expect(image.pixels == whole.pixels, "block \(block)")
        }
    }
}
