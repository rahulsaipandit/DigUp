// DOWNSTREAM-FORK (2026-11-17, security): new in the fork. Pins the two handle-leak fixes in FileReader(passedHandle:), found in the
// code review (docs/downstream-fork-changes.md).
#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import DigUpKit

@Suite(.serialized) struct FileReaderTests {
    static func handleCount() -> Int {
        var count: DWORD = 0
        GetProcessHandleCount(GetCurrentProcess(), &count)
        return Int(count)
    }

    /// A handle that is valid and that no file seek works on: an event.
    static func eventHandle() -> HANDLE { CreateEventW(nil, true, false, nil)! }

    @Test func aHandleThatCanSeekMakesAReaderThatReadsAndClosesItsHandles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DigUp-Reader-\(UUID().uuidString)")
        try Data("hello world".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let raw = CreateFileW(file.path.wide, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING),
                              DWORD(FILE_ATTRIBUTE_NORMAL), nil)!
        let before = Self.handleCount()
        do {
            let reader = try #require(FileReader(passedHandle: raw))
            #expect(reader.size == 11)
            var buffer = [UInt8](repeating: 0, count: 5)
            #expect(reader.read(at: 6, into: &buffer, count: 5) == 5 && buffer == Array("world".utf8))
        }
        #expect(Self.handleCount() <= before, "the reader closed what it held, and the handle it was given")
    }

    /// `_open_osfhandle` refuses a handle: the copy made first, and the handle that was passed, used to leak.
    @Test func aHandleTheRuntimeRefusesIsRefusedWithoutLeaking() {
        let rounds = 400
        let before = Self.handleCount()
        for _ in 0..<rounds { #expect(FileReader(passedHandle: Self.eventHandle()) == nil) }
        let grown = Self.handleCount() - before
        // A leak is one handle a round. The margin is for whatever else the test process opens meanwhile.
        #expect(grown < rounds / 4, "\(grown) handles left open after \(rounds) refusals")
    }

    /// A value that is no handle: `DuplicateHandle` fails, and nothing is left behind.
    @Test func aValueThatIsNoHandleIsRefused() {
        #expect(FileReader(passedHandle: nil) == nil)
        #expect(FileReader(passedHandle: INVALID_HANDLE_VALUE) == nil)
        #expect(FileReader(passedHandle: HANDLE(bitPattern: 0x7FFF_FFF0)) == nil)
    }
}
#endif
