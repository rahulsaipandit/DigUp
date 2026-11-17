// DOWNSTREAM-FORK (2026-11-16, security): this whole file is new in the fork. See docs/design.md ("Windows sandbox for the
// worker", stage 2) and docs/downstream-fork-changes.md.
//
// The AppContainer the decode worker runs as: an app identity with no capabilities. It has no network access and can read
// only what has been granted to it. One profile for this program, made the first time and found by name after that.
// Every folder it is granted is written to a list (`manifestPath`), so `digup sandbox-remove` can take the grants and the
// profile away again.
#if os(Windows)
import Foundation
import WinSDK

enum AppContainer {
    /// Letters, digits, dots, dashes and underscores only; 64 characters at most.
    static let defaultName = "DigUp.DecodeWorker"

    private typealias CreateProfile = @convention(c) (UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?,
                                                      UnsafeMutableRawPointer?, DWORD, UnsafeMutablePointer<PSID?>?) -> HRESULT
    private typealias DeriveSid = @convention(c) (UnsafePointer<UInt16>?, UnsafeMutablePointer<PSID?>?) -> HRESULT
    private typealias DeleteProfile = @convention(c) (UnsafePointer<UInt16>?) -> HRESULT
    private typealias FolderPath = @convention(c) (UnsafePointer<UInt16>?, UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?>?)
        -> HRESULT

    /// A function from userenv.dll, looked up by name so that the package needs no extra library on its link line.
    private static func userenv<F>(_ symbol: String, as: F.Type) throws -> F {
        // System32 only: a plain LoadLibraryW would also look in the current folder and on PATH, for a planted userenv.dll.
        guard let module = LoadLibraryExW("userenv.dll".wide, nil, DWORD(0x0000_0800)),   // LOAD_LIBRARY_SEARCH_SYSTEM32
              let address = GetProcAddress(module, symbol) else {
            throw SandboxError(step: "load \(symbol)", code: GetLastError())
        }
        return unsafeBitCast(address, to: F.self)
    }

    // MARK: the profile

    /// The container's SID, made if the profile doesn't exist yet.
    static func makeSid(_ name: String) -> Result<PSID, SandboxError> {
        do {
            var sid: PSID?
            let create = try userenv("CreateAppContainerProfile", as: CreateProfile.self)
            let made = create(name.wide, "DigUp decode worker".wide, "Reads files for DigUp in a sandbox".wide, nil, 0, &sid)
            if made == HRESULT(bitPattern: 0x8007_00B7) {   // ERROR_ALREADY_EXISTS: it's there from an earlier run
                let derive = try userenv("DeriveAppContainerSidFromAppContainerName", as: DeriveSid.self)
                let found = derive(name.wide, &sid)
                guard found >= 0, sid != nil else { throw SandboxError(step: "find container", code: UInt32(bitPattern: found)) }
            } else if made < 0 || sid == nil {
                throw SandboxError(step: "make container", code: UInt32(bitPattern: made))
            }
            return .success(sid!)
        } catch let error as SandboxError {
            return .failure(error)
        } catch {
            return .failure(SandboxError(step: "container", code: 0))
        }
    }

    /// A folder the container may write to, made if needed: its own `AC\Temp` under its profile.
    static func makeWorkFolder(_ sid: PSID) -> Result<String, SandboxError> {
        do {
            var text: LPWSTR?
            guard ConvertSidToStringSidW(sid, &text), let text else {
                throw SandboxError(step: "container SID", code: GetLastError())
            }
            defer { LocalFree(text) }
            let folderPath = try userenv("GetAppContainerFolderPath", as: FolderPath.self)
            var path: UnsafeMutablePointer<UInt16>?
            let got = folderPath(UnsafePointer(text), &path)
            guard got >= 0, let path else { throw SandboxError(step: "container folder", code: UInt32(bitPattern: got)) }
            defer { CoTaskMemFree(path) }
            let folder = String(decodingCString: path, as: UTF16.self) + "\\AC\\Temp"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            return .success(folder)
        } catch let error as SandboxError {
            return .failure(error)
        } catch {
            return .failure(SandboxError(step: "container folder", code: 0))
        }
    }

    /// Removes what a worker that was killed in the middle of a render left in the container's scratch folder: files not
    /// changed for `seconds` (a worker deletes each file as soon as it has sent it, and two helpers can have workers at the
    /// same time, so only the old ones are certainly left over). Returns how many it removed.
    @discardableResult
    static func sweepWorkFolder(_ folder: String, olderThan seconds: TimeInterval = 600) -> Int {
        let cutoff = Date().addingTimeInterval(-seconds)
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = folder + "\\" + name
            guard let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  changed < cutoff else { continue }
            if (try? FileManager.default.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed
    }

    nonisolated(unsafe) private static var swept = false

    /// The default container's scratch folder, swept once per process, the first time a worker is started.
    static func sweepDefaultWorkFolderOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !swept, case .success(let folder) = workFolder else { return }
        swept = true
        sweepWorkFolder(folder)
    }

    /// The profile and everything in its folder. Fine if there is none.
    @discardableResult
    static func deleteProfile(_ name: String) -> HRESULT {
        guard let delete = try? userenv("DeleteAppContainerProfile", as: DeleteProfile.self) else { return -1 }
        return delete(name.wide)
    }

    /// The default container, made when first needed. Kept for the life of the process.
    nonisolated(unsafe) static let sid: Result<PSID, SandboxError> = makeSid(defaultName)
    static let workFolder: Result<String, SandboxError> = {
        guard case .success(let sid) = sid else { return .failure(SandboxError(step: "container", code: 0)) }
        return makeWorkFolder(sid)
    }()

    // MARK: access to folders

    private static let lock = NSLock()
    nonisolated(unsafe) private static var granted: Set<String> = []

    /// Where the folders granted to the default container are listed, one to a line: under the user's local app data,
    /// where the container itself has no access.
    static var manifestPath: String {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return base + "\\DigUp\\sandbox-grants.txt"
    }

    static func manifestFolders(_ path: String = manifestPath) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func record(_ folder: String, in path: String) {
        guard !manifestFolders(path).contains(folder) else { return }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let line = Data((folder + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Changes the access list of `folder` for the container: `GRANT_ACCESS` adds read and execute for it (inherited by what
    /// is in the folder), `REVOKE_ACCESS` takes every entry of its away.
    private static func change(_ folder: String, for sid: PSID, mode: ACCESS_MODE) throws {
        var old: PACL?
        var descriptor: PSECURITY_DESCRIPTOR?
        var code = GetNamedSecurityInfoW(folder.wide, SE_FILE_OBJECT, SECURITY_INFORMATION(DACL_SECURITY_INFORMATION), nil, nil,
                                         &old, nil, &descriptor)
        guard code == 0 else { throw SandboxError(step: "read the access list of \(folder)", code: code) }
        defer { LocalFree(descriptor) }
        var entry = EXPLICIT_ACCESS_W()
        // FILE_GENERIC_READ (0x120089) and FILE_GENERIC_EXECUTE (0x1200A0), whose macros Swift can't import.
        entry.grfAccessPermissions = 0x0012_0089 | 0x0012_00A0
        entry.grfAccessMode = mode
        entry.grfInheritance = DWORD(CONTAINER_INHERIT_ACE | OBJECT_INHERIT_ACE)
        entry.Trustee.TrusteeForm = TRUSTEE_IS_SID
        entry.Trustee.TrusteeType = TRUSTEE_IS_UNKNOWN
        entry.Trustee.ptstrName = UnsafeMutablePointer<UInt16>(OpaquePointer(sid))
        var merged: PACL?
        code = SetEntriesInAclW(1, &entry, old, &merged)
        guard code == 0 else { throw SandboxError(step: "build the access list of \(folder)", code: code) }
        defer { LocalFree(merged) }
        var path = folder.wide
        code = SetNamedSecurityInfoW(&path, SE_FILE_OBJECT, SECURITY_INFORMATION(DACL_SECURITY_INFORMATION), nil, nil, merged, nil)
        guard code == 0 else { throw SandboxError(step: "change the access to \(folder)", code: code) }
    }

    /// Gives the default container read and execute on `folder` and what is in it, and lists the folder for removal. Once
    /// per folder per run.
    static func grantRead(_ folder: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !granted.contains(folder) else { return }
        guard case .success(let sid) = sid else { throw SandboxError(step: "container", code: 0) }
        try grantRead(folder, to: sid)
        record(folder, in: manifestPath)
        granted.insert(folder)
    }

    static func grantRead(_ folder: String, to sid: PSID) throws { try change(folder, for: sid, mode: GRANT_ACCESS) }
    static func revoke(_ folder: String, from sid: PSID) throws { try change(folder, for: sid, mode: REVOKE_ACCESS) }

    /// Whether the access list of `folder` has an entry that allows `sid` something.
    static func hasGrant(_ folder: String, for sid: PSID) -> Bool {
        var dacl: PACL?
        var descriptor: PSECURITY_DESCRIPTOR?
        guard GetNamedSecurityInfoW(folder.wide, SE_FILE_OBJECT, SECURITY_INFORMATION(DACL_SECURITY_INFORMATION), nil, nil,
                                    &dacl, nil, &descriptor) == 0, let dacl else { return false }
        defer { LocalFree(descriptor) }
        var info = ACL_SIZE_INFORMATION()
        guard GetAclInformation(dacl, &info, DWORD(MemoryLayout<ACL_SIZE_INFORMATION>.size), AclSizeInformation) else { return false }
        for index in 0..<info.AceCount {
            var entry: LPVOID?
            guard GetAce(dacl, index, &entry), let entry else { continue }
            guard entry.assumingMemoryBound(to: ACE_HEADER.self).pointee.AceType == 0 else { continue }   // ACCESS_ALLOWED_ACE_TYPE
            // The entry is a header (4 bytes), an access mask (4 bytes), then the SID.
            if EqualSid(entry + MemoryLayout<ACE_HEADER>.size + MemoryLayout<DWORD>.size, sid) { return true }
        }
        return false
    }

    // MARK: taking it all away

    /// Takes the container's access from the folders listed in `manifest`, those named in `extra`, and (for the default
    /// container) those this program would grant itself (`foldersNeeded`, which finds the grants of runs that made no list);
    /// then deletes the profile. Reports each step; returns whether all went well.
    @discardableResult
    static func removeAll(name: String = defaultName, manifest: String = manifestPath, extra: [String] = [],
                          report: (String) -> Void) -> Bool {
        var everything = true
        let found = makeSid(name)
        var folders = Set(manifestFolders(manifest) + extra)
        if name == defaultName, let executable = Bundle.main.executableURL {
            folders.formUnion(foldersNeeded(executable: executable))
        }
        switch found {
        case .success(let sid):
            for folder in folders.sorted() where FileManager.default.fileExists(atPath: folder) {
                guard hasGrant(folder, for: sid) else { continue }
                do {
                    try revoke(folder, from: sid)
                    report("took the container's access away from \(folder)")
                } catch {
                    report("couldn't take the access away from \(folder): \(error)")
                    everything = false
                }
            }
        case .failure(let error):
            report("couldn't find the container: \(error)")
            everything = false
        }
        let deleted = deleteProfile(name)
        if deleted >= 0 {
            report("deleted the container profile \(name)")
        } else if deleted == HRESULT(bitPattern: 0x8007_0490) {   // not there: nothing to delete
            report("no container profile \(name) to delete")
        } else {
            report("couldn't delete the container profile \(name) (0x\(String(UInt32(bitPattern: deleted), radix: 16)))")
            everything = false
        }
        if everything { try? FileManager.default.removeItem(atPath: manifest) }
        lock.lock(); granted.removeAll(); lock.unlock()
        return everything
    }

    // MARK: which folders to grant

    /// More folders to grant, for a parent that is not the worker's own program (development, and the tests, where the parent
    /// is a test runner that never loads the worker's llama.cpp and PDFium DLLs): DIGUP_SANDBOX_DLL_DIRS, separated by ";".
    @TaskLocal static var extraFolders: [String] = []

    /// The folders this program's own DLLs are loaded from (the worker is the same program, so it needs the same ones),
    /// and the program's own folder. Windows' own folders are left out: they already allow every app container to read.
    static func foldersNeeded(executable: URL) -> [String] {
        let windows = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows").lowercased()
        var folders: Set<String> = [executable.deletingLastPathComponent().path.replacingOccurrences(of: "/", with: "\\")]
        let named = (ProcessInfo.processInfo.environment["DIGUP_SANDBOX_DLL_DIRS"] ?? "").split(separator: ";").map(String.init)
        folders.formUnion((named + extraFolders).filter { !$0.isEmpty })
        let snapshot = CreateToolhelp32Snapshot(DWORD(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32), GetCurrentProcessId())
        guard snapshot != INVALID_HANDLE_VALUE else { return Array(folders) }
        defer { CloseHandle(snapshot) }
        var module = MODULEENTRY32W()
        module.dwSize = DWORD(MemoryLayout<MODULEENTRY32W>.size)
        var more = Module32FirstW(snapshot, &module)
        while more {
            let path = withUnsafePointer(to: &module.szExePath) {
                $0.withMemoryRebound(to: UInt16.self, capacity: Int(MAX_PATH)) { String(decodingCString: $0, as: UTF16.self) }
            }
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.lowercased().hasPrefix(windows) { folders.insert(folder) }
            more = Module32NextW(snapshot, &module)
        }
        return Array(folders)
    }
}

extension String {
    /// UTF-16 with a terminating NUL, for the wide Windows calls.
    var wide: [UInt16] { Array(utf16) + [0] }
}

/// `digup sandbox-remove [folder...]`: takes the decode worker's sandbox away: the container's access to the folders it was
/// granted (those listed when granted, those this program would grant, and any named here) and the container profile.
public enum SandboxCleanup {
    public static func run(extraFolders: [String]) -> Int32 {
        let ok = AppContainer.removeAll(extra: extraFolders) { print($0) }
        print(ok ? "done" : "done, with problems")
        return ok ? 0 : 1
    }
}
#else
import Foundation

/// The sandbox is Windows only; there is nothing to take away.
public enum SandboxCleanup {
    public static func run(extraFolders: [String]) -> Int32 {
        print("sandbox-remove: nothing to remove on this system")
        return 0
    }
}
#endif
