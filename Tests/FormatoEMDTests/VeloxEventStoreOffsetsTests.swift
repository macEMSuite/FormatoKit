//
//  VeloxEventStoreOffsetsTests.swift
//  The event store's count, scatter and per-pixel reads share one offsets array (macEMSuite/FormatoKit#109): every pixel's
//  spectrum equals a plain count of the streams, with empty first and last pixels, several streams and out-of-range
//  channels.
//

import Foundation
import Testing
import FormatoCore
import FormatoEMD

@Suite struct VeloxEventStoreOffsetsTests {
    private let marker = VeloxStreamDecoder.pixelMarker

    /// A deterministic stream: `frames` frames of `pixels` pixels, each pixel 0...3 events of channels 0..<10 (8 and 9 are
    /// out of range for 8 channels), pixel 0 and the last pixel always empty.
    private func stream(seed: UInt64, pixels: Int, frames: Int) -> [UInt16] {
        var state = seed
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        var out: [UInt16] = []
        for _ in 0..<frames {
            for p in 0..<pixels {
                if p != 0 && p != pixels - 1 { for _ in 0..<(next() % 4) { out.append(UInt16(next() % 10)) } }
                out.append(marker)
            }
        }
        return out
    }

    @Test func everyPixelsSpectrumEqualsAPlainCountOfTheStreams() throws {
        let (ny, nx, channels, frames) = (3, 5, 8, 4)
        let pixels = ny * nx
        let streams = [stream(seed: 1, pixels: pixels, frames: frames), stream(seed: 2, pixels: pixels, frames: frames)]
        let store = try VeloxStreamDecoder.buildEventStore(
            arrays: streams, geometry: VeloxStreamGeometry(ny: ny, nx: nx, channels: channels), frames: 1..<3)
        var want = [[UInt32]](repeating: [UInt32](repeating: 0, count: channels), count: pixels)
        var outOfRange = 0
        for s in streams {
            var (frame, p) = (0, 0)
            for v in s {
                if v == marker { p += 1; if p == pixels { p = 0; frame += 1 }; continue }
                guard (1..<3).contains(frame) else { continue }
                if Int(v) < channels { want[p][Int(v)] += 1 } else { outOfRange += 1 }
            }
        }
        for p in 0..<pixels { #expect(store.spectrum(pixel: p) == want[p], "pixel \(p)") }
        #expect(store.outOfRangeValues == outOfRange)
        #expect(store.rowOffsets.count == pixels + 1 && store.rowOffsets.first == 0)
        #expect(store.rowOffsets.last == store.channelIndex.count)
    }
}
