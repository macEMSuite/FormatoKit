//
//  TIFFStoredImageTests.swift
//  TIFFAppImage.readStored (FormatoKit#115): the pixels at the file's stored type, every value equal to the stored one, and
//  widened to Float exactly `read`'s pixels, on every app-image and LZW fixture (both byte orders, every sample type, RGB
//  renders, strips longer than the image) and on a planted large 8-bit file that costs one byte a pixel.
//

import Foundation
import Testing
import FormatoCore
import FormatoTIFF

@Suite struct TIFFStoredImageTests {
    static let lzw = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lzw")

    static func paths() throws -> [String] {
        let names = TIFFAppImageTests.pins.map { $0["name"] as! String }.map(TIFFAppImageTests.path)
        let lzwNames = try FileManager.default.contentsOfDirectory(atPath: Self.lzw.path).filter { $0.hasSuffix(".tif") }.sorted()
            .map { Self.lzw.appendingPathComponent($0).path }
        return names + lzwNames
    }

    /// Every fixture: the stored reading is the Float reading but for the type of the pixels; a refusal is the same refusal.
    @Test func testStoredReadingIsTheFloatReadingOnEveryFixture() throws {
        var read = 0
        for path in try Self.paths() {
            let float: TIFFAppImage.Image
            do { float = try TIFFAppImage.read(path: path) } catch {
                do {
                    _ = try TIFFAppImage.readStored(path: path)
                    Issue.record("\(path): read refuses (\(error)), readStored reads")
                } catch let stored { #expect("\(stored)" == "\(error)", "\(path)") }
                continue
            }
            read += 1
            let stored = try TIFFAppImage.readStored(path: path)
            #expect(stored.width == float.width && stored.height == float.height, "\(path)")
            #expect(stored.pixels.shape == [float.height, float.width], "\(path)")
            #expect(stored.pixels.floats().map(\.bitPattern) == float.pixels.map(\.bitPattern), "\(path)")
            #expect(stored.x == float.x && stored.y == float.y, "\(path)")
            #expect(stored.source == float.source && stored.notes == float.notes && stored.fileName == float.fileName, "\(path)")
        }
        #expect(read > 102, "the 102 app-image readings and the LZW files")
    }

    /// The stored type of each sample fixture, in both byte orders, and the 8- and 16-bit values as stored. Red before:
    /// `readStored` did not exist.
    @Test func testEachSampleTypeKeepsItsStoredType() throws {
        let types: [String: FormatoDataType] = ["u8": .uint8, "u16": .uint16, "u32": .uint32, "i8": .int8, "i16": .int16,
                                                "i32": .int32, "f32": .float32, "f64": .float64]
        for (sample, type) in types {
            for order in ["II", "MM"] {
                let name = "sample-\(sample)-\(order)"
                let image = try TIFFAppImage.readStored(path: TIFFAppImageTests.path(name))
                #expect(image.pixels.dataType == type, "\(name)")
                #expect(image.pixels.bytes.count == image.width * image.height * type.byteSize, "\(name): the stored size, no more")
                if ["u8", "u16", "i8", "i16"].contains(sample) {
                    // Exact in Float, so the pinned Float pixels are the stored integers.
                    let pinned = (TIFFAppImageTests.pin(name)["pixels"] as! [Int]).map { Double(Float(bitPattern: UInt32($0))) }
                    #expect(image.pixels.doubles() == pinned, "\(name)")
                }
            }
        }
        // An exported grey render is its one grey channel, one byte a pixel; unequal channels are refused as by `read`.
        let render = try TIFFAppImage.readStored(path: TIFFAppImageTests.path("rgb-grey-II"))
        #expect(render.pixels.dataType == .uint8)
        #expect(render.notes.contains(TIFFAppImage.Note.render))
        #expect(throws: TIFFAppImage.Refusal.self) { try TIFFAppImage.readStored(path: TIFFAppImageTests.path("rgb-unequal-red-first-pixel")) }
    }

    /// A planted 4096 x 4096 8-bit TIFF (16 MiB of pixels) reads to exactly its stored bytes: one byte a pixel, where the
    /// Float reading holds four.
    @Test func testALargeEightBitImageHoldsOneByteAPixel() throws {
        let side = 4096
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices { pixels[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i / side) }
        let file = Self.plantedGrey8(width: side, height: side, pixels: pixels)
        let image = try TIFFAppImage.readStored(data: file, fileName: "planted.tif")
        #expect(image.pixels.dataType == .uint8)
        #expect(image.pixels.bytes.count == side * side)
        #expect(image.pixels.bytes.elementsEqual(pixels))
    }

    /// A little-endian baseline TIFF: one strip of 8-bit grey, BlackIsZero.
    static func plantedGrey8(width: Int, height: Int, pixels: [UInt8]) -> Data {
        var d = Data([0x49, 0x49, 42, 0])
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(8)
        let tags: [(code: Int, type: Int, value: Int)] = [
            (256, 4, width), (257, 4, height), (258, 3, 8), (259, 3, 1), (262, 3, 1),
            (273, 4, 8 + 2 + 9 * 12 + 4), (277, 3, 1), (278, 4, height), (279, 4, width * height),
        ]
        u16(tags.count)
        for t in tags {
            u16(t.code); u16(t.type); u32(1)
            if t.type == 3 { u16(t.value); u16(0) } else { u32(t.value) }
        }
        u32(0)
        d.append(contentsOf: pixels)
        return d
    }
}
