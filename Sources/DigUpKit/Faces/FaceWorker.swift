// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md 5.1). Talks to `digup-faces` (faces-rs), the face program, over
// stdin and stdout, one JSON line each way, in the manner of `EmbeddingWorker`. It sends paths of pictures the sandboxed decode already wrote,
// never pixels. A program that dies or takes too long is ended, and the caller records the files as failed: a face problem never fails a file.
import Foundation

public enum FaceWorkerError: Error, CustomStringConvertible {
    case notFound(String), died(String), failed(String), timedOut
    public var description: String {
        switch self {
        case .notFound(let message), .failed(let message): return message
        case .died(let message): return "the face program stopped: \(message)"
        case .timedOut: return "the face program took too long and was stopped"
        }
    }
}

public struct FaceResult: Sendable {
    public var path: String
    public var width = 0, height = 0
    public var detections: [Detection] = []
    /// Set when the picture could not be read or the models failed on it.
    public var error: String?
}

public final class FaceWorker {
    /// What the program reports as its detector, alignment and embedder, recorded with every scan.
    public static let signature = "yunet-640+sface-128/1"

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let log: URL?
    private let timeout: TimeInterval

    /// `executable`: `digup-faces`. `models`: the folder holding `yunet.onnx` and `sface.onnx` (the program checks their hashes and refuses others).
    public init(executable: URL, models: URL, threads: Int = 2, log: URL? = nil, timeout: TimeInterval = 120,
                qos: QualityOfService = .utility) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw FaceWorkerError.notFound("the face program is missing: \(executable.path)")
        }
        self.log = log
        self.timeout = timeout
        process.executableURL = executable
        process.qualityOfService = qos
        process.arguments = ["--models", models.path, "--threads", String(threads)]
        process.standardInput = input
        process.standardOutput = output
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: log)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let ready = try readReply(waiting: 60)
        guard ready["ready"] as? Bool == true else {
            close()
            throw FaceWorkerError.failed((ready["error"] as? String) ?? "the face program did not start")
        }
        guard ready["signature"] as? String == Self.signature else {
            close()
            throw FaceWorkerError.failed("the face program reports \(ready["signature"] ?? "no model"), not \(Self.signature)")
        }
    }

    deinit { close() }

    public var isRunning: Bool { process.isRunning }

    /// Faces in each picture, in order. A picture that fails comes back with its `error`; a program that dies throws.
    public func faces(in paths: [String], score: Double = 0.5) throws -> [FaceResult] {
        guard !paths.isEmpty else { return [] }
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["id": id, "op": "faces", "paths": paths, "score": score]
        do {
            try input.fileHandleForWriting.write(contentsOf: try JSONSerialization.data(withJSONObject: request) + [0x0A])
        } catch {
            throw FaceWorkerError.died("cannot write to it\(logTail())")
        }
        let reply = try readReply(waiting: timeout * Double(max(1, paths.count)) / 8 + 10)
        guard reply["id"] as? Int == id, reply["ok"] as? Bool == true, let results = reply["results"] as? [[String: Any]] else {
            throw FaceWorkerError.failed((reply["error"] as? String) ?? "no results")
        }
        return results.map(Self.result)
    }

    static func result(_ json: [String: Any]) -> FaceResult {
        var result = FaceResult(path: json["path"] as? String ?? "")
        if let error = json["error"] as? String { result.error = error; return result }
        result.width = json["width"] as? Int ?? 0
        result.height = json["height"] as? Int ?? 0
        for face in json["faces"] as? [[String: Any]] ?? [] {
            guard let box = face["box"] as? [Double], box.count == 4, let text = face["embedding"] as? String,
                  let data = Data(base64Encoded: text), data.count >= 4 else { continue }
            result.detections.append(Detection(
                box: FaceBox(x: box[0], y: box[1], w: box[2], h: box[3]),
                landmarks: (face["landmarks"] as? [Double]).flatMap { $0.count == 10 ? $0 : nil },
                confidence: face["score"] as? Double ?? 0, sharpness: face["sharpness"] as? Double ?? 0,
                embedding: floats(data)))
        }
        return result
    }

    public func close() {
        guard process.isRunning else { return }
        if let line = try? JSONSerialization.data(withJSONObject: ["id": 0, "op": "quit"]) {
            try? input.fileHandleForWriting.write(contentsOf: line + [0x0A])
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
    }

    /// Reads one reply line. A program that says nothing for `waiting` seconds is ended (the read then fails as a death, reported as a time-out).
    private func readReply(waiting: TimeInterval) throws -> [String: Any] {
        let timedOut = LockedFlag()
        let watchdog = DispatchWorkItem { [process] in
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + waiting, execute: watchdog)
        defer { watchdog.cancel() }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw FaceWorkerError.failed("the face program sent something that is not a reply")
                }
                return object
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                if timedOut.isSet { throw FaceWorkerError.timedOut }
                throw FaceWorkerError.died("exited\(logTail())")
            }
            buffer.append(chunk)
        }
    }

    private func logTail() -> String {
        guard let log, let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let tail = text.split(separator: "\n").suffix(4).joined(separator: "\n  ")
        return tail.isEmpty ? "" : "; its log (\(log.path)):\n  \(tail)"
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
