//
//  ArrayTests.swift
//  The lazy-read check's reference half: `FormatoArray.slab` cut in C order, checked against an index-by-index cut; and the lazy file
//  array equal to the eager one on every seeded slab. Mutations: the row stride off by one (13),
//  `start` ignored (14) - red.
//

import Foundation
import Testing
import FormatoCore

@Suite struct ArrayTests {
    private func iota(_ shape: [Int], _ type: FormatoDataType = .int16) throws -> FormatoArray {
        let n = try FormatoArray.elementCount(shape)
        var d = Data()
        for i in 0..<n { var v = Int16(truncatingIfNeeded: i * 7 - 300).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return try FormatoArray(dataType: type, shape: shape, bytes: d)
    }

    /// The value at a multi-index, computed directly from the C-order formula.
    private func value(_ a: FormatoArray, _ index: [Int]) -> Double {
        var flat = 0
        for (k, i) in index.enumerated() { flat = flat * a.shape[k] + i }
        return a.doubles()[flat]
    }

    @Test func testSlabMatchesIndexByIndexCut() throws {
        let a = try iota([4, 5, 6])
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        for _ in 0..<200 {
            let start = a.shape.map { next($0 + 1) }
            let count = zip(start, a.shape).map { s, n in next(n - s + 1) }
            let s = try a.slab(start: start, count: count)
            #expect(s.shape == count)
            let got = s.doubles()
            var k = 0
            for i in 0..<count[0] { for j in 0..<count[1] { for l in 0..<count[2] {
                #expect(got[k] == value(a, [start[0] + i, start[1] + j, start[2] + l])); k += 1
            } } }
            #expect(k == got.count)
        }
        #expect(throws: FormatoArrayError.self) { try a.slab(start: [0, 0, 5], count: [1, 1, 2]) }
        #expect(throws: FormatoArrayError.self) { try a.slab(start: [0, 0], count: [1, 1]) }
    }

    @Test func testFileArrayEqualsEagerOnSeededSlabs() throws {
        let a = try iota([3, 4, 5])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("formato-array-\(UUID().uuidString).bin")
        var file = Data(repeating: 0xAB, count: 37)            // a header the array must skip
        file.append(a.bytes); file.append(Data(repeating: 0xCD, count: 11))
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lazy = FormatoFileArray(path: url.path, offset: 37, dataType: .int16, shape: [3, 4, 5])
        #expect(try lazy.readAll() == a)
        var seed: UInt64 = 12345
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        for _ in 0..<200 {
            let start = a.shape.map { next($0 + 1) }
            let count = zip(start, a.shape).map { s, n in next(n - s + 1) }
            #expect(try lazy.read(start: start, count: count) == a.slab(start: start, count: count), "\(start) \(count)")
        }
        let short = FormatoFileArray(path: url.path, offset: 60, dataType: .int16, shape: [3, 4, 5])
        #expect(throws: FormatoReadError.truncated(url.lastPathComponent)) { try short.readAll() }
    }

    /// `floats()` (FormatoKit#115): each type widened as Float32 holds it; a float32 is its stored bits (a NaN payload kept),
    /// integers and float64 rounded once. Red before: `floats()` did not exist.
    @Test func testFloatsWidenEachStoredType() throws {
        func array<T>(_ type: FormatoDataType, _ values: [T]) throws -> FormatoArray {
            try FormatoArray(dataType: type, shape: [values.count], bytes: values.withUnsafeBytes { Data($0) })
        }
        #expect(try array(.uint8, [UInt8(0), 1, 255]).floats() == [0, 1, 255])
        #expect(try array(.int8, [Int8(-128), -1, 127]).floats() == [-128, -1, 127])
        #expect(try array(.uint16, [UInt16(0), 300, 65535]).floats() == [0, 300, 65535])
        #expect(try array(.int16, [Int16(-32768), 0, 32767]).floats() == [-32768, 0, 32767])
        #expect(try array(.uint32, [UInt32(16_777_217)]).floats() == [Float(16_777_217 as UInt32)])
        #expect(try array(.int32, [Int32(-16_777_217)]).floats() == [Float(-16_777_217 as Int32)])
        let nan = Float(bitPattern: 0x7FC0_1234)
        #expect(try array(.float32, [Float(-0.0), Float.leastNormalMagnitude / 4, nan]).floats().map(\.bitPattern) == [Float(-0.0), Float.leastNormalMagnitude / 4, nan].map(\.bitPattern))
        #expect(try array(.float64, [0.1, 1e300]).floats() == [Float(0.1 as Double), Float(1e300 as Double)])
        let rgb = try FormatoArray(dataType: .rgb8, shape: [2], bytes: Data([1, 2, 3, 4, 5, 6]))
        #expect(rgb.floats() == [1, 2, 3, 4, 5, 6])
    }

    @Test func testByteCountAndShapeAreChecked() {
        #expect(throws: FormatoArrayError.byteCountMismatch(expected: 16, got: 15)) { try FormatoArray(dataType: .float32, shape: [2, 2], bytes: Data(count: 15)) }
        #expect(throws: FormatoArrayError.invalidShape([-1])) { try FormatoArray(dataType: .float32, shape: [-1], bytes: Data()) }
        #expect(throws: Never.self) { try FormatoArray(dataType: .float64, shape: [0, 3], bytes: Data()) }
    }
}
