//
//  TIFFAllocationBoundTests.swift
//  A TIFF's declared sizes never make the reader copy or decode more than the file holds (macEMSuite/FormatoKit#109).
//  Red before: strips that point at the same bytes were copied once each; tags that point at the same bytes were copied
//  and decoded once each; an LZW page's claimed size was checked against the whole file, not its strips; a slab of a
//  compressed page decoded every strip of the page.
//

import Foundation
import Testing
import FormatoCore
@testable import FormatoTIFF

@Suite struct TIFFAllocationBoundTests {

    enum Value { case inline(UInt32), at(Int) }

    /// A little-endian, one-directory TIFF: header, the directory at 8, then `payload`. `.at(k)` is payload offset `k`.
    static func tiff(_ entries: [(UInt16, UInt16, UInt32, Value)], payload: [UInt8]) -> Data {
        let base = 8 + 2 + entries.count * 12 + 4
        var b: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        func u16(_ v: UInt16) { b += [UInt8(v & 0xff), UInt8(v >> 8)] }
        func u32(_ v: UInt32) { b += (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        u16(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            u16(tag); u16(type); u32(count)
            switch value {
            case .inline(let v): u32(v)
            case .at(let k): u32(UInt32(base + k))
            }
        }
        u32(0)
        return Data(b + payload)
    }

    static func u32s(_ values: [Int]) -> [UInt8] {
        values.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    }

    /// An 8 x 8 uint8 image whose pixels are 0...63, with `strips` strips that all point at those 64 bytes.
    static func repeatedStrips(_ strips: Int) -> Data {
        let pixels = (0..<64).map(UInt8.init)
        let offsetsAt = pixels.count, countsAt = offsetsAt + 4 * strips
        let base = 8 + 2 + 9 * 12 + 4
        let payload = pixels + u32s(Array(repeating: base, count: strips)) + u32s(Array(repeating: 64, count: strips))
        return tiff([(256, 3, 1, .inline(8)), (257, 3, 1, .inline(8)), (258, 3, 1, .inline(8)), (259, 3, 1, .inline(1)),
                     (262, 3, 1, .inline(1)), (273, 4, UInt32(strips), strips == 1 ? .inline(UInt32(base)) : .at(offsetsAt)),
                     (277, 3, 1, .inline(1)), (278, 3, 1, .inline(8)),
                     (279, 4, UInt32(strips), strips == 1 ? .inline(64) : .at(countsAt))], payload: payload)
    }

    @Test func stripsThatHoldMoreThanTheFileAreRefusedBeforeTheyAreCopied() throws {
        let one = try TIFFAppImage.readStored(data: Self.repeatedStrips(1), fileName: "one.tif")
        #expect(one.pixels.bytes == Data((0..<64).map(UInt8.init)))
        let crafted = Self.repeatedStrips(200)
        #expect(200 * 64 > crafted.count)
        #expect(throws: TIFFAppImage.Refusal.truncated) { try TIFFAppImage.readStored(data: crafted, fileName: "crafted.tif") }
    }

    @Test func tagValuesThatHoldMoreThanTheFileAreRefusedBeforeTheyAreCopied() throws {
        // One 64 KiB blob, and 20 private tags of 64 KiB each that all point at it: 1.25 MiB of values in a 64 KiB file.
        let blob = [UInt8](repeating: 9, count: 1 << 16)
        func file(privateTags: Int) -> Data {
            let pixelAt = blob.count
            var entries: [(UInt16, UInt16, UInt32, Value)] = [
                (256, 3, 1, .inline(1)), (257, 3, 1, .inline(1)), (258, 3, 1, .inline(8)), (259, 3, 1, .inline(1)),
                (262, 3, 1, .inline(1)), (273, 4, 1, .at(pixelAt)), (277, 3, 1, .inline(1)), (278, 3, 1, .inline(1)),
                (279, 4, 1, .inline(1)),
            ]
            for k in 0..<privateTags { entries.append((UInt16(65000 + k), 1, UInt32(blob.count), .at(0))) }
            return Self.tiff(entries, payload: blob + [7])
        }
        let fine = try TIFFAppImage.read(data: file(privateTags: 1), fileName: "fine.tif")
        #expect(fine.pixels == [7])
        let crafted = file(privateTags: 20)
        #expect(20 * blob.count > crafted.count + TIFFFile.tagValueSlack)
        #expect(throws: TIFFError.self) { _ = try TIFFFile(data: crafted) }
        #expect(throws: TIFFAppImage.Refusal.truncated) { try TIFFAppImage.read(data: crafted, fileName: "crafted.tif") }
    }

    @Test func anLZWPageLargerThanItsStripsCanGiveIsRefusedBeforeAllocating() {
        // 4000 x 4000 uint8 from a 10-byte strip in an 8 KiB file: 2731 x 8 KiB covers the claim, 2731 x 10 bytes does not.
        let strip: [UInt8] = [0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let padding = [UInt8](repeating: 0, count: 8192)
        let data = Self.tiff([(256, 3, 1, .inline(4000)), (257, 3, 1, .inline(4000)), (258, 3, 1, .inline(8)),
                              (259, 3, 1, .inline(5)), (262, 3, 1, .inline(1)), (273, 4, 1, .at(0)), (277, 3, 1, .inline(1)),
                              (278, 3, 1, .inline(4000)), (279, 4, 1, .inline(UInt32(strip.count)))],
                             payload: strip + padding)
        #expect(4000 * 4000 / 2731 <= data.count)
        #expect(throws: TIFFAppImage.Refusal.truncated) { try TIFFAppImage.readStored(data: data, fileName: "lzw.tif") }
    }

    /// Codes packed MSB first at the given widths.
    static func pack(_ codes: [(Int, Int)]) -> [UInt8] {
        var bits: [Bool] = []
        for (code, width) in codes {
            for k in stride(from: width - 1, through: 0, by: -1) { bits.append((code >> k) & 1 == 1) }
        }
        while bits.count % 8 != 0 { bits.append(false) }
        return stride(from: 0, to: bits.count, by: 8).map { i in bits[i..<(i + 8)].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) } }
    }

    @Test func aSlabOfACompressedPageDecodesOnlyTheStripsThatHoldItsRows() throws {
        // 4 x 4 uint8, LZW, two rows per strip. The first strip holds 10...17; the second is corrupt (a code not yet in
        // the table), so decoding it fails.
        let good = Self.pack([(256, 9)] + (10..<18).map { ($0, 9) } + [(257, 9)])
        let corrupt = Self.pack([(256, 9), (65, 9), (300, 9)])
        let data = Self.tiff([(256, 3, 1, .inline(4)), (257, 3, 1, .inline(4)), (258, 3, 1, .inline(8)), (259, 3, 1, .inline(5)),
                              (262, 3, 1, .inline(1)), (273, 4, 2, .at(good.count + corrupt.count)), (277, 3, 1, .inline(1)),
                              (278, 3, 1, .inline(2)), (279, 4, 2, .at(good.count + corrupt.count + 8))],
                             payload: good + corrupt + Self.u32s([8 + 2 + 9 * 12 + 4, 8 + 2 + 9 * 12 + 4 + good.count])
                                 + Self.u32s([good.count, corrupt.count]))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fk109-slab-\(UUID().uuidString).tif").path
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tiff = try TIFFSignals(path: path)
        let lazy = TIFFSeriesArray(path: path, series: tiff.series[0], shape: tiff.series[0].shape)
        let slab = try lazy.read(start: [1, 1], count: [1, 2])
        #expect(slab.doubles() == [15, 16])
        #expect(throws: (any Error).self) { _ = try lazy.read(start: [2, 0], count: [1, 4]) }
    }
}
