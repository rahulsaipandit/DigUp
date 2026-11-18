// DOWNSTREAM-FORK (2026-11-17): person recognition (docs/person-recognition.md). Plain types shared by the face store,
// clustering, matching and name search. Nothing here touches a model: embeddings arrive from a face worker later.
import Foundation

/// A face's box in the coordinates of the picture the detector saw (the embedder's prepared picture, pixels).
public struct FaceBox: Equatable, Codable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { (self.x, self.y, self.w, self.h) = (x, y, w, h) }
    /// The smaller side, in pixels of the prepared picture: the "size" the floors and thresholds use.
    public var pixels: Double { min(w, h) }
}

/// One detection as a face worker reports it.
public struct Detection: Sendable {
    public var box: FaceBox
    /// YuNet's five landmarks as x,y pairs (right eye, left eye, nose, right mouth corner, left mouth corner), or nil.
    public var landmarks: [Double]?
    public var confidence: Double
    /// Laplacian variance of the face box in the prepared picture (unit: that picture's pixels).
    public var sharpness: Double
    public var embedding: [Float]
    /// The prepared picture's scale against the original, and the orientation applied (EXIF 1...8), so a box can be drawn on the original.
    public var scale: Double
    public var orientation: Int

    public init(box: FaceBox, landmarks: [Double]? = nil, confidence: Double, sharpness: Double, embedding: [Float],
                scale: Double = 1, orientation: Int = 1) {
        self.box = box; self.landmarks = landmarks; self.confidence = confidence; self.sharpness = sharpness
        self.embedding = embedding; self.scale = scale; self.orientation = orientation
    }
}

public struct FaceRecord: Sendable {
    public var id: Int64
    public var path: String
    public var size: Int64
    public var mtime: Int64
    public var taken: Int64?
    public var contentKey: String?
    public var box: FaceBox
    public var landmarks: [Double]?
    public var confidence: Double
    public var sharpness: Double
    public var embedding: [Float]

    /// Head turn from the landmarks (nose against the eyes' midpoint, in eye distances): 0 is frontal. Nil without landmarks.
    public var yaw: Double? {
        guard let l = landmarks, l.count == 10 else { return nil }
        let eyes = hypot(l[2] - l[0], l[3] - l[1])
        guard eyes > 0 else { return nil }
        return (l[4] - (l[0] + l[2]) / 2) / eyes
    }
    /// What counts as one photo: the content key when known (copies share it), else the path.
    public var photo: String { contentKey ?? path }
}

public enum LabelSource: String, Sendable {
    case user, group, auto, ignored
}

public struct Person: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var aliases: [String]
    public var isPrivate: Bool
}

public struct PersonSummary: Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var aliases: [String]
    public var photos: Int
}

/// What a label looks like to a caller. A label is anchored by path and box with its own copy of the embedding, so it
/// does not depend on a `face` row existing.
public struct FaceLabel: Sendable {
    public var id: Int64
    public var path: String
    public var box: FaceBox
    public var faceID: Int64?
    public var personID: Int64?
    public var source: LabelSource
    public var confidence: Double
}

public struct AlbumEntry: Equatable, Sendable {
    public var path: String
    /// Other paths with the same content key (copies, shown as copies and not as other photos).
    public var copies: [String]
    public var taken: Int64
}

/// The numbers every decision uses. One source of truth (rows 6 and 9 of §17): stored in `meta`, defaults only here.
/// Similarities are cosines of L2-normalised embeddings, higher is closer.
public struct FaceThresholds: Codable, Equatable, Sendable {
    /// Hard floor: a detection below either is never stored (alignment and embedding are meaningless there).
    public var floorConfidence = 0.5
    public var floorPixels = 20.0
    /// Soft thresholds: whether a stored face is usable. Changing them rescans nothing.
    public var usableConfidence = 0.7
    public var usablePixels = 40.0
    public var usableSharpness = 0.0
    /// Matching a face to a person (the tablet's 0.363 is the starting value) and the runner-up margin.
    public var matching = 0.363
    public var margin = 0.05
    /// Clustering unnamed faces is stricter than matching, and a separate setting.
    public var clustering = 0.45
    public var neighbours = 80
    public var rounds = 20
    public var seed: UInt64 = 20261117
    /// A group is offered only with this many faces from this many different photos (by content key).
    public var groupFaces = 3
    public var groupPhotos = 2
    /// The core of a person: a face qualifies when it matches this many other labelled faces; at most `coreSize` are kept.
    public var coreSupport = 3
    public var coreSize = 20
    /// A person is "enrolled" with this many varied faces; fewer is said so.
    public var enrolFaces = 5
    /// How often a file whose face scan failed is tried again.
    public var maxAttempts = 3

    public static let defaults = FaceThresholds()
    public init() {}
}

func floats(_ data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func blob(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

func normalised(_ values: [Float]) -> [Float] {
    let length = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return length > 0 ? values.map { $0 / length } : values
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
    return sum
}
