// DOWNSTREAM-FORK (2026-11-18): `digup faces` and the face questions of `search-service` (docs/person-recognition.md §10, §17).
import DigUpKit
import Foundation

private func cropJSON(_ crop: FaceCrop) -> [String: Any] {
    ["id": crop.id, "path": crop.path, "x": crop.box.x, "y": crop.box.y, "w": crop.box.w, "h": crop.box.h]
}

/// The face questions a shell asks (`faces_*` ops), answered from the faces file as the *search* service, which owns people and corrections.
/// Groups are made by the index service (or `digup faces group`); this only reads them and writes names.
func faceOp(_ op: String, _ request: [String: Any], store: FaceStore) throws -> [String: Any] {
    func int(_ key: String) throws -> Int64 {
        guard let value = (request[key] as? NSNumber)?.int64Value else { throw CLIError("\(op) needs \(key)") }
        return value
    }
    func name() throws -> String {
        let text = (request["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200 else { throw CLIError("a name needs 1 to 200 characters") }
        return text
    }
    switch op {
    case "faces_status":
        let c = try store.counts()
        return ["faces": c.faces, "photos": c.photosWithFaces, "scanned": c.scanned, "failed": c.failed, "groups": c.groups,
                "people": c.people, "named_faces": c.namedFaces, "unnamed_faces": c.ungroupedFaces]
    case "faces_groups":
        let sample = min(max(request["sample"] as? Int ?? 6, 1), 12)
        let limit = request["limit"] as? Int ?? 100
        let groups = try store.unnamedGroups(sample: sample)
        return ["total": groups.count, "groups": groups.prefix(limit).map {
            ["id": $0.group.id, "faces": $0.group.faceIDs.count, "photos": $0.group.photos, "samples": $0.samples.map(cropJSON)] as [String: Any]
        }]
    case "faces_group":
        let id = try int("group")
        guard let group = try store.groups().first(where: { $0.id == id }) else { throw CLIError("there is no group \(id)") }
        let limit = request["limit"] as? Int ?? 80
        return ["faces": try store.crops(ids: Array(group.faceIDs.prefix(limit))).map(cropJSON), "total": group.faceIDs.count]
    case "faces_people":
        return ["people": try store.summaries().map { person in
            var row: [String: Any] = ["id": person.id, "name": person.name, "aliases": person.aliases, "photos": person.photos]
            if let face = try store.sampleFaces(ofPerson: person.id, limit: 1).first { row["sample"] = cropJSON(face) }
            return row
        }]
    case "faces_person":
        let id = try int("person")
        let limit = request["limit"] as? Int ?? 60
        return ["faces": try store.sampleFaces(ofPerson: id, limit: limit).map(cropJSON)]
    case "faces_album":
        let id = try int("person")
        let entries = try store.album(of: id)
        return ["photos": entries.prefix(request["limit"] as? Int ?? 200).map { ["path": $0.path, "taken": $0.taken, "copies": $0.copies.count] as [String: Any] },
                "total": entries.count]
    case "faces_name":
        // A group becomes a new person, or (with `person`) joins one that exists: its faces are confirmed one by one for that person.
        let group = try int("group")
        if let person = (request["person"] as? NSNumber)?.int64Value {
            try store.add(group: group, to: person)
            return ["person": person]
        }
        return ["person": try store.name(group: group, as: try name())]
    case "faces_rename":
        try store.rename(person: try int("person"), to: try name())
        return ["ok": true]
    case "faces_merge":
        try store.merge(person: try int("from"), into: try int("into"))
        return ["ok": true]
    case "faces_ignore_group":
        try store.ignore(group: try int("group"))
        return ["ok": true]
    case "faces_ignore":
        try store.ignore(faces: (request["faces"] as? [NSNumber] ?? []).map(\.int64Value))
        return ["ok": true]
    case "faces_not_person":
        try store.reject(face: try int("face"), notPerson: try int("person"))
        return ["ok": true]
    case "faces_undo":
        return ["undone": (try store.undo()) ?? NSNull()]
    default:
        throw CLIError("unknown op \(op)")
    }
}

/// `digup faces <what>`: for the developer; the shell's People window uses the same operations through `search-service`.
///   status | group | groups [-n N] | people | name <group> <name…> | undo
func facesCommand(_ args: Arguments) throws -> Int32 {
    let what = args.positional.first ?? "status"
    let rest = Array(args.positional.dropFirst())
    func show(_ value: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }
    if what == "group" {
        // The index service's job done by hand: match faces to people, then cluster the rest into groups.
        let store = try FaceStore(directory: args.indexFolder, role: .index)
        let started = Date()
        let groups = try store.recluster()
        print("\(groups.count) groups from \(try store.faceCount()) faces in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for group in groups.sorted(by: { $0.faceIDs.count > $1.faceIDs.count }).prefix(15) {
            print("  group \(group.id): \(group.faceIDs.count) faces in \(group.photos) photos")
        }
        return 0
    }
    let store = try FaceStore(directory: args.indexFolder, role: .search)
    switch what {
    case "status": show(try faceOp("faces_status", [:], store: store))
    case "groups": show(try faceOp("faces_groups", ["limit": args.values["-n"].flatMap(Int.init) ?? 20], store: store))
    case "people": show(try faceOp("faces_people", [:], store: store))
    case "name":
        guard rest.count >= 2, let group = Int64(rest[0]) else { throw CLIError("usage: digup faces name <group> <name…>") }
        show(try faceOp("faces_name", ["group": group, "name": rest.dropFirst().joined(separator: " ")], store: store))
    case "undo": show(try faceOp("faces_undo", [:], store: store))
    default: throw CLIError("digup faces status|group|groups|people|name <group> <name>|undo")
    }
    return 0
}
