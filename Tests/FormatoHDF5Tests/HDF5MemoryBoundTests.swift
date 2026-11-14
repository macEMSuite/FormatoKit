//
//  HDF5MemoryBoundTests.swift
//  An HDF5 read never allocates more than its limit, or what the file can give (macEMSuite/FormatoKit#109).
//  Red before: the slab reader and the datacube had no byte limit, and the slab reader allocated before it checked the slab;
//  the LZF filter allocated the chunk size the file claims; a variable-length string was copied whatever its length.
//

import Foundation
import Testing
import FormatoCore
import FormatoHDF5

@Suite struct HDF5MemoryBoundTests {
    static let assorted = HDF5ReaderTests.fixture("assorted.h5")
    static let datacube = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/emd-bundle/app-datacube.h5")

    @Test func theSlabReaderRefusesASlabOverItsLimitAsReadDatasetDoes() throws {
        let held = try HDF5SlabReader(url: Self.assorted, path: "/a/data/f32")
        let whole = held.shape.reduce(1, *) * 4
        let slab = try held.read(start: held.shape.map { _ in 0 }, count: held.shape, maximumBytes: whole)
        #expect(slab.bytes.count == whole)
        #expect(throws: HDF5FileError.self) {
            _ = try held.read(start: held.shape.map { _ in 0 }, count: held.shape, maximumBytes: whole - 1)
        }
        #expect(throws: HDF5FileError.self) {
            _ = try HDF5Reader(url: Self.assorted).readDataset("/a/data/f32", maximumBytes: whole - 1)
        }
        // A slab past the dataset is refused before anything is allocated, never a trap on its size.
        #expect(throws: HDF5FileError.self) { _ = try held.read(start: [0, 0, 0], count: [Int.max / 2, 4, 4]) }
        held.close()
    }

    @Test func theDatacubeRefusesASlabOverItsLimit() throws {
        let cube = try HDF5Datacube(path: Self.datacube.path, datasetPath: "/datacube_root/datacube/data")
        let one = cube.shape.enumerated().map { $0.offset < 2 ? 1 : $0.element }
        let bytes = one.reduce(1, *) * cube.dataType.byteSize
        let start = cube.shape.map { _ in 0 }
        #expect(try cube.read(start: start, count: one, maximumBytes: bytes).bytes.count == bytes)
        #expect(throws: HDF5DatacubeError.self) { _ = try cube.read(start: start, count: one, maximumBytes: bytes - 1) }
    }

    @Test func theLZFFilterMeasuresAClaimLargerThanItsInputCanGive() {
        // Five bytes give 100 'a's. A claimed chunk of 1 MiB is past 5 x 88 bytes: the output is measured, not allocated.
        let stream: [UInt8] = [0, 0x61, 0xE0, 90, 0], a100 = [UInt8](repeating: 0x61, count: 100)
        let claimed = LZFTests.filter(stream, chunkBytes: 1 << 20)
        #expect(claimed.returned == 100 && claimed.bytes == a100)
        #expect(claimed.size == 100)
        // A claim the input can give is taken as h5py takes it.
        let fits = LZFTests.filter(stream, chunkBytes: 400)
        #expect(fits.returned == 100 && fits.size == 400 && fits.bytes == a100)
        // A stream that cannot decode fails without allocating the claim.
        #expect(LZFTests.filter([0x80, 0], chunkBytes: 1 << 20).returned == 0)
    }

    @Test func aCStringIsCopiedOnlyWhenItFits() {
        let text = "four"
        text.withCString { pointer in
            #expect(boundedCString(pointer, maximumBytes: 4) == "four")
            #expect(boundedCString(pointer, maximumBytes: 3) == nil)
            #expect(boundedCString(pointer, maximumBytes: 1 << 20) == "four")
        }
        "".withCString { #expect(boundedCString($0, maximumBytes: 0) == "") }
    }
}
