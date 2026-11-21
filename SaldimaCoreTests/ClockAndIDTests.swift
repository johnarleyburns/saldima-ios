// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

import SaldimaTestKit
@testable import SaldimaCore

@Suite("Clock seam")
struct ClockTests {
    @Test("manual clock starts where the test says and advances only on command")
    func manualClock() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualClock(start)
        #expect(clock.now() == start)
        try clock.advance(by: 60)
        #expect(clock.now() == start.addingTimeInterval(60))
        clock.set(Date(timeIntervalSince1970: 0))
        #expect(clock.now() == Date(timeIntervalSince1970: 0))
    }

    @Test("manual clock refuses to move backwards")
    func manualClockBackwards() {
        let clock = ManualClock()
        #expect(throws: ClockError.negativeAdvance) {
            try clock.advance(by: -1)
        }
    }

    @Test("system clock reads through its injected provider")
    func systemClockInjected() {
        let fixed = Date(timeIntervalSince1970: 1_234)
        let clock = SystemClock { fixed }
        #expect(clock.now() == fixed)
    }
}

@Suite("IDGenerator seam")
struct IDGeneratorTests {
    @Test("seeded GUIDs are valid, deterministic and unique")
    func seededIDs() {
        let ids = SeededIDGenerator()
        var seen = Set<Guid>()
        for _ in 0..<500 {
            let guid = ids.guid()
            #expect(guid.rawValue.count == 32)
            #expect(guid.rawValue == guid.rawValue.lowercased())
            let isHex = guid.rawValue.allSatisfy { $0.isHexDigit }
            #expect(isHex)
            #expect(!seen.contains(guid))
            seen.insert(guid)
        }
    }

    @Test("the same seed replays the same GUIDs")
    func seededReplay() {
        #expect(SeededIDGenerator(start: 7).guid() == SeededIDGenerator(start: 7).guid())
    }

    @Test("system generator converts an injected UUID")
    func systemIDInjected() {
        let uuid = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let ids = SystemIDGenerator { uuid }
        #expect(ids.guid().rawValue == "0123456789abcdef0123456789abcdef")
    }

    @Test("Guid validates its input")
    func guidValidation() {
        #expect(Guid("0123456789abcdef0123456789abcdef") != nil)
        #expect(Guid("0123456789ABCDEF0123456789abcdef") == nil)
        #expect(Guid("short") == nil)
    }
}
