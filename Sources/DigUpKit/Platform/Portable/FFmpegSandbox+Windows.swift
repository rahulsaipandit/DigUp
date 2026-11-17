// DOWNSTREAM-FORK (2026-11-17, security): this whole file is new in the fork. See docs/design.md ("ffmpeg in the sandbox") and
// docs/downstream-fork-changes.md.
//
// ffmpeg and ffprobe in the AppContainer (Windows), with the same job object and mitigation policies as the decode worker.
// Neither is given a path to open. The one file a call reads is opened here and handed over as the program's standard input,
// and the call's input argument becomes `-fd 0 -i fd:` (ffmpeg's `fd` protocol: it reads that descriptor and can seek in it, which
// `pipe:` cannot, and an MP4 with its index at the end needs). What a call writes goes to stdout, which comes back on a pipe,
// or, for the pictures `ffmpeg` writes as files (`frame`, `keyframes`), to a scratch folder inside the container that this
// side then moves to where the caller asked.
//
// If the sandbox cannot be set up, the call fails: it does not run ffmpeg outside the sandbox.
#if os(Windows)
import Foundation

/// Counts the ffmpeg and ffprobe launches made in the sandbox, for a test that needs to tell the sandbox from a plain launch (a
/// call that works either way proves nothing about which it was).
enum SandboxLaunches {
    /// What a test sets to count the launches made in its own task (other tests run side by side and launch their own).
    final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return started }
        func record() { lock.lock(); started += 1; lock.unlock() }
    }

    @TaskLocal static var tracker: Tracker?

    static func record() { tracker?.record() }
}

extension FFmpeg {
    /// Which argument names the file a call reads, and that file: the one after `-i` for ffmpeg, the last for ffprobe.
    private static func inputArgument(in arguments: [String], tool: String) -> (index: Int, file: URL)? {
        let probe = (tool as NSString).lastPathComponent.lowercased().hasPrefix("ffprobe")
        let index: Int
        if probe {
            index = arguments.count - 1
        } else if let flag = arguments.firstIndex(of: "-i"), flag + 1 < arguments.count {
            index = flag + 1
        } else {
            return nil
        }
        guard index >= 0 else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: arguments[index], isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return (index, URL(fileURLWithPath: arguments[index]))
    }

    /// `FFmpeg.run` in the sandbox: the same arguments and the same bytes to `read`, and the same error when the tool fails.
    static func runSandboxed(_ tool: String, _ arguments: [String], read: (Data) throws -> Void) throws {
        let name = (tool as NSString).lastPathComponent
        guard let (inputIndex, file) = inputArgument(in: arguments, tool: tool) else {
            throw ExtractError.unreadable("\(name) was given no file to read")
        }
        guard case .success(let work) = AppContainer.workFolder else {
            if case .failure(let error) = AppContainer.workFolder { throw ExtractError.unreadable("\(error)") }
            throw ExtractError.unreadable("\(name) has no scratch folder")
        }
        var arguments = arguments
        // `-fd 0 -i fd:`: read descriptor 0, which is the file (this build's `fd` protocol takes the number as an option, not in
        // the URL). ffprobe has no `-i` in the calls made here, ffmpeg has.
        if inputIndex > 0, arguments[inputIndex - 1] == "-i" {
            arguments.replaceSubrange((inputIndex - 1)...inputIndex, with: ["-fd", "0", "-i", "fd:"])
        } else {
            arguments.replaceSubrange(inputIndex...inputIndex, with: ["-fd", "0", "-i", "fd:"])
        }

        // What ffmpeg writes as files goes to a folder of the container's own, and is moved to where the caller asked.
        let scratch = work + "\\ffmpeg-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        var destination: String?
        if !name.lowercased().hasPrefix("ffprobe"), let last = arguments.last, last != "-" {
            let folder = (last as NSString).deletingLastPathComponent
            if !folder.isEmpty, FileManager.default.fileExists(atPath: folder) {
                try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
                arguments[arguments.count - 1] = scratch + "\\" + (last as NSString).lastPathComponent
                destination = folder
            }
        }

        // The whole environment, as the decode worker gets it (a bare one made the launch fail with Windows error 203), with the
        // temporary folder the container's own.
        var environment = ProcessInfo.processInfo.environment
        environment["TEMP"] = work
        environment["TMP"] = work
        let program = URL(fileURLWithPath: tool)
        let folder = program.deletingLastPathComponent().path.replacingOccurrences(of: "/", with: "\\")
        let process: SandboxedProcess
        do {
            process = try SandboxedProcess(executable: program, arguments: arguments, environment: environment,
                                           standardInput: file, grantFolders: [folder])
        } catch {
            let message = "\(name) couldn't start: \(error)"
            DecodeLog.note(message)   // the app shows nothing per file
            throw ExtractError.unreadable(message)
        }
        defer { process.close() }
        SandboxLaunches.record()
        while true {
            let data = process.read()
            if data.isEmpty { break }
            try read(data)
        }
        let code = process.exitCode()
        // The pictures a run wrote, even when it ended with an error: ffmpeg does that for the frames it could not decode on the
        // way to the one it wrote (see `VideoExtractor.frame`).
        if let destination {
            for written in (try? FileManager.default.contentsOfDirectory(atPath: scratch)) ?? [] {
                let target = destination + "\\" + written
                try? FileManager.default.removeItem(atPath: target)
                try? FileManager.default.moveItem(atPath: scratch + "\\" + written, toPath: target)
            }
        }
        guard code == 0 else { throw ExtractError.unreadable("\(name) failed (\(code.map(String.init) ?? "no exit code"))") }
    }
}
#endif
