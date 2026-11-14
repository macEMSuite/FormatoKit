//
//  MRCStoredImageTests.swift
//  MRCAppImage.readStored (FormatoKit#115): the pixels at the mode's stored type, every value equal to the stored one, and
//  widened to Float exactly `read`'s pixels, on every fixture and on planted big-endian 16-bit files.
//

import Foundation
import Testing
import FormatoCore
import FormatoMRC

@Suite struct MRCStoredImageTests {

    /// Every fixture: the stored reading is the Float reading but for the type of the pixels; a refusal is the same refusal.
    @Test func testStoredReadingIsTheFloatReadingOnEveryFixture() throws {
        var read = 0
        for c in MRCImageTests.pins {
            let name = c["name"] as! String
            let path = MRCImageTests.path(name)
            let float: MRCAppImage.Image
            do { float = try MRCAppImage.read(path: path) } catch {
                do {
                    _ = try MRCAppImage.readStored(path: path)
                    Issue.record("\(name): read refuses (\(error)), readStored reads")
                } catch let stored { #expect("\(stored)" == "\(error)", "\(name)") }
                continue
            }
            read += 1
            let stored = try MRCAppImage.readStored(path: path)
            #expect(stored.width == float.width && stored.height == float.height, "\(name)")
            #expect(stored.pixels.shape == [float.height, float.width], "\(name)")
            #expect(stored.pixels.floats().map(\.bitPattern) == float.pixels.map(\.bitPattern), "\(name)")
            #expect(stored.x == float.x && stored.y == float.y, "\(name)")
            #expect(stored.source == float.source && stored.notes == float.notes && stored.fileName == float.fileName, "\(name)")
        }
        #expect(read == 12)
    }

    /// The stored type per mode, and the values as stored. Red before: `readStored` did not exist.
    @Test func testEachModeKeepsItsStoredType() throws {
        func stored(_ name: String) throws -> FormatoArray { try MRCAppImage.readStored(path: MRCImageTests.path(name)).pixels }
        #expect(try stored("int8-signed").dataType == .int8)
        #expect(try stored("int8-signed").doubles() == [0, 127, -128, -1])
        #expect(try stored("int8-signed").bytes.count == 4, "one byte a pixel")
        #expect(try stored("int16").dataType == .int16)
        #expect(try stored("int16").doubles() == [-32768, 0, 1, 32767])
        #expect(try stored("uint16").dataType == .uint16)
        #expect(try stored("uint16").doubles() == [0, 1, 65535, 300])
        #expect(try stored("uint16").bytes.count == 8, "two bytes a pixel")
        #expect(try stored("f32-3x2").dataType == .float32)
        #expect(try stored("big-endian").doubles() == [1, 2, 3, 4])
        // Float16 has no stored type here: widened exactly to float32.
        #expect(try stored("float16").dataType == .float32)
        #expect(try stored("float16").doubles() == [0.5, -2, 65504, 0.00010001659393310547])
    }

    /// A planted big-endian (stamp 11 11) 16-bit file, unsigned and signed: swapped to little-endian, value for value.
    @Test func testABigEndian16BitFileIsSwappedExactly() throws {
        for (mode, type) in [(6, FormatoDataType.uint16), (1, .int16)] {
            var header = [UInt8](repeating: 0, count: 1024)
            func put(_ index: Int, _ value: Int32) {
                withUnsafeBytes(of: value.bigEndian) { header.replaceSubrange(4 * index..<4 * index + 4, with: $0) }
            }
            put(0, 3); put(1, 2); put(2, 1); put(3, Int32(mode)); put(16, 1); put(17, 2); put(18, 3)
            header.replaceSubrange(208..<212, with: Array("MAP ".utf8)); header.replaceSubrange(212..<216, with: [0x11, 0x11, 0, 0])
            let values: [UInt16] = [0, 1, 0x0102, 0x7FFF, 0x8000, 0xFFFF]
            var body = Data(header)
            for v in values { withUnsafeBytes(of: v.bigEndian) { body.append(contentsOf: $0) } }
            let image = try MRCAppImage.readStored(data: body, fileName: "planted.mrc")
            #expect(image.pixels.dataType == type)
            var little = Data()
            for v in values { withUnsafeBytes(of: v.littleEndian) { little.append(contentsOf: $0) } }
            #expect(image.pixels.bytes == little, "mode \(mode)")
            let float = try MRCAppImage.read(data: body, fileName: "planted.mrc")
            #expect(image.pixels.floats() == float.pixels)
        }
    }
}
