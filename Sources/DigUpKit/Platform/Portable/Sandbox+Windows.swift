// DOWNSTREAM-FORK (2026-11-16, security): this whole file is new in the fork. See docs/design.md ("Windows sandbox for the
// worker") and docs/downstream-fork-changes.md.
//
// Stage 1 of the Windows sandbox: the decode worker is started with CreateProcessW, not Foundation's Process, so that the
// launch can set what Process can't:
//   - a job object: a memory cap, kill-on-close, one process only, and UI restrictions (no clipboard, desktop, display
//     settings, system parameters, global atoms, exit-windows);
//   - process mitigation policies: heap corruption ends the process, high-entropy and bottom-up ASLR, strict handle
//     checks, no legacy extension points, control-flow guard, and image loads only from local, normal-integrity places
//     with System32 preferred;
//   - no child processes (the child-process policy, and the job's limit of one);
//   - only the worker's three standard handles are inherited (a handle list).
// Stage 2 (AppContainer+Windows.swift, and below): the worker is also an AppContainer, an app identity with no
// capabilities, so it has no network access and can read only what has been granted to it. The helper grants it read and
// execute on the folders its own DLLs come from (the worker is the same program), hands it the PDF as an open handle
// (`passFile`), and gives it a folder of its own to render into (`workFolder`), whose files come back as bytes in the
// reply. It can open no other file. If any step of this fails, the worker is not started: nothing falls back to a plain
// launch.
#if os(Windows)
import Foundation
import WinSDK

struct SandboxError: Error, CustomStringConvertible {
    let step: String
    let code: UInt32
    var description: String { "sandbox: \(step) failed (Windows error \(code))" }
}

enum SandboxPolicy {
    /// DIGUP_SANDBOX=0 starts the worker with Foundation's Process instead, for debugging. Read from this process's own
    /// environment, never from a file.
    static var enabled: Bool { forced ?? (ProcessInfo.processInfo.environment["DIGUP_SANDBOX"] != "0") }

    /// What a test sets for the code it runs (a task-local, so tests that run side by side don't see each other's).
    @TaskLocal static var forced: Bool?

    /// The most memory the worker may use, in bytes (DIGUP_DECODE_MEMORY_MB, default 4 GiB).
    static var memoryLimit: Int {
        let megabytes = ProcessInfo.processInfo.environment["DIGUP_DECODE_MEMORY_MB"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        return (megabytes ?? 4096) * 1024 * 1024
    }

    // Process creation mitigation policy flags (winbase.h), spelled out because Swift can't import their macros.
    static let heapTerminate: UInt64 = 1 << 12          // PROCESS_CREATION_MITIGATION_POLICY_HEAP_TERMINATE_ALWAYS_ON
    static let bottomUpASLR: UInt64 = 1 << 16
    static let highEntropyASLR: UInt64 = 1 << 20
    static let strictHandleChecks: UInt64 = 1 << 24
    static let extensionPointDisable: UInt64 = 1 << 32
    static let controlFlowGuard: UInt64 = 1 << 40
    static let imageLoadNoRemote: UInt64 = 1 << 52
    static let imageLoadNoLowLabel: UInt64 = 1 << 56
    static let imageLoadPreferSystem32: UInt64 = 1 << 60
    // Left out on purpose: dynamic-code prohibition, win32k lockdown, font disable and Microsoft-only binaries, none of
    // which is known to be safe with PDFium or with this program's own unsigned DLLs.
    static let mitigations: UInt64 = heapTerminate | bottomUpASLR | highEntropyASLR | strictHandleChecks
        | extensionPointDisable | controlFlowGuard | imageLoadNoRemote | imageLoadNoLowLabel | imageLoadPreferSystem32

    // Attributes for UpdateProcThreadAttribute (their macros can't be imported either).
    static let attributeHandleList: DWORD_PTR = 0x0002_0002
    static let attributeMitigationPolicy: DWORD_PTR = 0x0002_0007
    static let attributeChildProcessPolicy: DWORD_PTR = 0x0002_000E
    static let attributeSecurityCapabilities: DWORD_PTR = 0x0002_0009
    static let childProcessRestricted: UInt32 = 0x01      // PROCESS_CREATION_CHILD_PROCESS_RESTRICTED
}

/// A worker started under the job object and mitigation policies above, talking over two anonymous pipes.
final class SandboxedProcess: DecodeChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var process: HANDLE?
    private var job: HANDLE?
    private var toChild: HANDLE?
    private var fromChild: HANDLE?
    let workFolder: String?

    /// `standardInput`: a file to give the program as its standard input, read-only, instead of a pipe it can be written to
    /// (ffmpeg reads its one file that way). `grantFolders`: the folders the container may read, when they are not the ones
    /// this program's own DLLs come from (ffmpeg is a program of its own).
    init(executable: URL, arguments: [String], environment: [String: String], standardInput: URL? = nil,
         grantFolders: [String]? = nil) throws {
        // The container, and read access for it to the folders the worker's own files are in.
        guard case .success(let containerSid) = AppContainer.sid else {
            if case .failure(let error) = AppContainer.sid { throw error }
            throw SandboxError(step: "container", code: 0)
        }
        guard case .success(let work) = AppContainer.workFolder else {
            if case .failure(let error) = AppContainer.workFolder { throw error }
            throw SandboxError(step: "container folder", code: 0)
        }
        for folder in grantFolders ?? AppContainer.foldersNeeded(executable: executable) { try AppContainer.grantRead(folder) }
        self.workFolder = work
        AppContainer.sweepDefaultWorkFolderOnce()   // what a killed worker left, if anything
        var closeOnFailure: [HANDLE?] = []
        var succeeded = false
        defer { if !succeeded { for handle in closeOnFailure where handle != nil { CloseHandle(handle) } } }
        func keep(_ handle: HANDLE?) -> HANDLE? { closeOnFailure.append(handle); return handle }

        // The pipes: the child's ends are inheritable, ours are not.
        var inheritable = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                              lpSecurityDescriptor: nil, bInheritHandle: true)
        var childIn: HANDLE?, ourWrite: HANDLE?, ourRead: HANDLE?, childOut: HANDLE?
        if let file = standardInput {
            // The file itself, opened here for reading: the program has no right to open it by path.
            childIn = CreateFileW(file.path.wide, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                                  &inheritable, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            guard childIn != INVALID_HANDLE_VALUE else { throw SandboxError(step: "open \(file.lastPathComponent)", code: GetLastError()) }
            _ = keep(childIn)
        } else {
            guard CreatePipe(&childIn, &ourWrite, &inheritable, 0) else { throw SandboxError(step: "pipe", code: GetLastError()) }
            _ = keep(childIn); _ = keep(ourWrite)
        }
        guard CreatePipe(&ourRead, &childOut, &inheritable, 0) else { throw SandboxError(step: "pipe", code: GetLastError()) }
        _ = keep(ourRead); _ = keep(childOut)
        guard ourWrite == nil || SetHandleInformation(ourWrite, DWORD(HANDLE_FLAG_INHERIT), 0),
              SetHandleInformation(ourRead, DWORD(HANDLE_FLAG_INHERIT), 0)
        else { throw SandboxError(step: "pipe handles", code: GetLastError()) }
        // The worker's standard error goes nowhere.
        let nul = keep(CreateFileW("NUL".wide, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &inheritable,
                                   DWORD(OPEN_EXISTING), 0, nil))
        guard nul != INVALID_HANDLE_VALUE else { throw SandboxError(step: "null device", code: GetLastError()) }

        // The job, made before the process so that no moment exists where the worker runs outside it.
        guard let jobHandle = CreateJobObjectW(nil, nil) else { throw SandboxError(step: "job", code: GetLastError()) }
        _ = keep(jobHandle)
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS
            | JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION)
        limits.BasicLimitInformation.ActiveProcessLimit = 1
        limits.ProcessMemoryLimit = SIZE_T(SandboxPolicy.memoryLimit)
        guard SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, &limits,
                                      DWORD(MemoryLayout.size(ofValue: limits))) else {
            throw SandboxError(step: "job limits", code: GetLastError())
        }
        // The UI restrictions (no clipboard, desktop, display settings, system parameters, global atoms, exit-windows). Not when this
        // process is already in a job that has them, as it is under the shell (helper.rs puts every helper in one that does): Windows
        // refuses to nest a job with UI restrictions inside one that has them too ("assign to job failed", error 50), and the
        // worker is bound by the parent's anyway. (The first version set them always, and the sandbox did not start under the
        // shell at all: scripts/fork-tests/job-nesting.bat.)
        var parentUI = JOBOBJECT_BASIC_UI_RESTRICTIONS()
        let parentRestrictsUI = QueryInformationJobObject(nil, JobObjectBasicUIRestrictions, &parentUI,
                                                          DWORD(MemoryLayout.size(ofValue: parentUI)), nil)
            && parentUI.UIRestrictionsClass != 0
        if !parentRestrictsUI {
            var ui = JOBOBJECT_BASIC_UI_RESTRICTIONS(UIRestrictionsClass: DWORD(JOB_OBJECT_UILIMIT_DESKTOP
                | JOB_OBJECT_UILIMIT_DISPLAYSETTINGS | JOB_OBJECT_UILIMIT_EXITWINDOWS | JOB_OBJECT_UILIMIT_GLOBALATOMS
                | JOB_OBJECT_UILIMIT_READCLIPBOARD | JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS | JOB_OBJECT_UILIMIT_WRITECLIPBOARD))
            guard SetInformationJobObject(jobHandle, JobObjectBasicUIRestrictions, &ui, DWORD(MemoryLayout.size(ofValue: ui))) else {
                throw SandboxError(step: "job UI restrictions", code: GetLastError())
            }
        }

        // The attributes: which handles are inherited, the mitigation policies, and no child processes.
        var listSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 4, 0, &listSize)   // fails, and says how much room it needs
        let listMemory = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
        defer { listMemory.deallocate() }
        var startup = STARTUPINFOEXW()
        startup.lpAttributeList = .init(listMemory)
        let list = startup.lpAttributeList
        guard InitializeProcThreadAttributeList(list, 4, 0, &listSize) else {
            throw SandboxError(step: "attribute list", code: GetLastError())
        }
        defer { DeleteProcThreadAttributeList(list) }
        // Each value lives until CreateProcessW has returned.
        let inherited = UnsafeMutablePointer<HANDLE?>.allocate(capacity: 3)
        inherited.initialize(from: [childIn, childOut, nul], count: 3)
        defer { inherited.deallocate() }
        let policy = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        policy.initialize(to: SandboxPolicy.mitigations)
        defer { policy.deallocate() }
        let children = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        children.initialize(to: SandboxPolicy.childProcessRestricted)
        defer { children.deallocate() }
        let capabilities = UnsafeMutablePointer<SECURITY_CAPABILITIES>.allocate(capacity: 1)
        capabilities.initialize(to: SECURITY_CAPABILITIES(AppContainerSid: containerSid, Capabilities: nil, CapabilityCount: 0,
                                                          Reserved: 0))
        defer { capabilities.deallocate() }
        guard UpdateProcThreadAttribute(list, 0, SandboxPolicy.attributeSecurityCapabilities, capabilities,
                                        SIZE_T(MemoryLayout<SECURITY_CAPABILITIES>.size), nil, nil) else {
            throw SandboxError(step: "app container", code: GetLastError())
        }
        guard UpdateProcThreadAttribute(list, 0, SandboxPolicy.attributeHandleList, inherited,
                                        SIZE_T(3 * MemoryLayout<HANDLE?>.size), nil, nil) else {
            throw SandboxError(step: "handle list", code: GetLastError())
        }
        guard UpdateProcThreadAttribute(list, 0, SandboxPolicy.attributeMitigationPolicy, policy, SIZE_T(MemoryLayout<UInt64>.size),
                                        nil, nil) else {
            throw SandboxError(step: "mitigation policy", code: GetLastError())
        }
        guard UpdateProcThreadAttribute(list, 0, SandboxPolicy.attributeChildProcessPolicy, children,
                                        SIZE_T(MemoryLayout<UInt32>.size), nil, nil) else {
            throw SandboxError(step: "child process policy", code: GetLastError())
        }

        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.StartupInfo.hStdInput = childIn
        startup.StartupInfo.hStdOutput = childOut
        startup.StartupInfo.hStdError = nul

        var commandLine = ([executable.path] + arguments).map(Self.quoted).joined(separator: " ").wide
        var environmentBlock = Self.environmentBlock(environment)
        var info = PROCESS_INFORMATION()
        // Suspended, so it can join the job before it runs a single instruction. DETACHED_PROCESS, not CREATE_NO_WINDOW: the
        // helper is a console program, and a hidden console is served by a conhost.exe the child-process policy then
        // refuses to start, which ends the worker with STATUS_DLL_INIT_FAILED (0xC0000142). It reads and writes its
        // pipes, so it needs no console.
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT)
        let created = environmentBlock.withUnsafeMutableBytes { block in
            withUnsafeMutablePointer(to: &startup) { pointer in
                pointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { basic in
                    CreateProcessW(nil, &commandLine, nil, nil, true, flags, block.baseAddress, nil, basic, &info)
                }
            }
        }
        guard created else { throw SandboxError(step: "start", code: GetLastError()) }
        _ = keep(info.hProcess); _ = keep(info.hThread)
        guard AssignProcessToJobObject(jobHandle, info.hProcess) else {
            let code = GetLastError()
            TerminateProcess(info.hProcess, 1)
            throw SandboxError(step: "assign to job", code: code)
        }
        guard ResumeThread(info.hThread) != DWORD.max else {
            let code = GetLastError()
            TerminateProcess(info.hProcess, 1)
            throw SandboxError(step: "resume", code: code)
        }
        // The child's ends and its thread are no longer ours to hold.
        CloseHandle(info.hThread); CloseHandle(childIn); CloseHandle(childOut); CloseHandle(nul)
        succeeded = true
        process = info.hProcess
        job = jobHandle
        toChild = ourWrite
        fromChild = ourRead
    }

    deinit { close() }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let process else { return false }
        return WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT)
    }

    func write(_ data: Data) throws {
        lock.lock()
        let handle = toChild
        lock.unlock()
        guard let handle else { throw SandboxError(step: "write", code: DWORD(ERROR_BROKEN_PIPE)) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                var written: DWORD = 0
                guard WriteFile(handle, buffer.baseAddress! + offset, DWORD(buffer.count - offset), &written, nil), written > 0
                else { throw SandboxError(step: "write", code: GetLastError()) }
                offset += Int(written)
            }
        }
    }

    func read() -> Data {
        lock.lock()
        let handle = fromChild
        lock.unlock()
        guard let handle else { return Data() }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var count: DWORD = 0
        guard ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil), count > 0 else { return Data() }
        return Data(buffer[0..<Int(count)])
    }

    func terminate() {
        lock.lock(); defer { lock.unlock() }
        if let job { TerminateJobObject(job, 1) }
    }

    /// Opens `url` read-only here and duplicates the handle into the worker, which has no right to open it itself.
    func passFile(_ url: URL) throws -> Int? {
        lock.lock()
        let target = process
        lock.unlock()
        guard let target else { throw SandboxError(step: "pass the file", code: DWORD(ERROR_INVALID_HANDLE)) }
        let local = CreateFileW(url.path.wide, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                                nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        guard local != INVALID_HANDLE_VALUE else { throw SandboxError(step: "open \(url.lastPathComponent)", code: GetLastError()) }
        defer { CloseHandle(local) }
        var remote: HANDLE?
        guard DuplicateHandle(GetCurrentProcess(), local, target, &remote, DWORD(GENERIC_READ), false, 0), let remote else {
            throw SandboxError(step: "hand over the file", code: GetLastError())
        }
        return Int(bitPattern: remote)
    }

    /// The program's exit code, once it has ended (waits a few seconds for it to).
    func exitCode() -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        guard let process, WaitForSingleObject(process, 5000) == DWORD(WAIT_OBJECT_0) else { return nil }
        var code: DWORD = 0
        return GetExitCodeProcess(process, &code) ? code : nil
    }

    func exitStatus() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let process else { return nil }
        // The pipe can close a moment before the process is gone.
        guard WaitForSingleObject(process, 2000) == DWORD(WAIT_OBJECT_0) else { return nil }
        var code: DWORD = 0
        guard GetExitCodeProcess(process, &code) else { return nil }
        return "exit code 0x" + String(code, radix: 16, uppercase: true)
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        // Closing the job ends the worker (kill-on-close), then the pipes and the process handle go.
        for handle in [job, toChild, fromChild, process] where handle != nil { CloseHandle(handle) }
        (job, toChild, fromChild, process) = (nil, nil, nil, nil)
    }

    /// One argument, quoted for the command line the way CommandLineToArgvW reads it back.
    private static func quoted(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" { backslashes += 1; continue }
            if character == "\"" { result += String(repeating: "\\", count: backslashes * 2 + 1) + "\"" }
            else { result += String(repeating: "\\", count: backslashes) + String(character) }
            backslashes = 0
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    /// `name=value` entries, each ended by a NUL and the whole ended by another, in UTF-16.
    private static func environmentBlock(_ environment: [String: String]) -> [UInt8] {
        var units: [UInt16] = []
        for (name, value) in environment.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            units += Array("\(name)=\(value)".utf16) + [0]
        }
        units.append(0)
        return units.withUnsafeBufferPointer { Array(UnsafeRawBufferPointer($0)) }
    }
}

/// What a worker reports about its own sandbox, for the tests (the worker's `selftest.*` operations).
enum SandboxProbe {
    /// The job the calling process is in: whether there is one, and its limits.
    static func job() -> [String: Any] {
        var inJob: WindowsBool = false
        guard IsProcessInJob(GetCurrentProcess(), nil, &inJob), inJob.boolValue else { return ["inJob": false] }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        // A null job handle asks about the job the calling process is in.
        guard QueryInformationJobObject(nil, JobObjectExtendedLimitInformation, &limits,
                                        DWORD(MemoryLayout.size(ofValue: limits)), nil) else { return ["inJob": true] }
        var ui = JOBOBJECT_BASIC_UI_RESTRICTIONS()
        _ = QueryInformationJobObject(nil, JobObjectBasicUIRestrictions, &ui, DWORD(MemoryLayout.size(ofValue: ui)), nil)
        return ["inJob": true,
                "flags": Int(limits.BasicLimitInformation.LimitFlags),
                "activeProcessLimit": Int(limits.BasicLimitInformation.ActiveProcessLimit),
                "memoryLimit": Int(limits.ProcessMemoryLimit),
                "ui": Int(ui.UIRestrictionsClass)]
    }

    /// Tries to open a TCP connection to this machine on `port`, as an exploited decoder sending data out might.
    static func connects(toLoopbackPort port: Int) -> Bool {
        var data = WSADATA()
        guard WSAStartup(0x0202, &data) == 0 else { return false }
        defer { WSACleanup() }
        let handle = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP.rawValue))
        guard handle != INVALID_SOCKET else { return false }
        defer { closesocket(handle) }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.S_un.S_addr = 0x0100_007F   // 127.0.0.1, as the bytes 7F 00 00 01
        // Not waiting for the system's own timeout (about 20 seconds when the connection is blocked): two seconds.
        var nonBlocking: u_long = 1
        _ = ioctlsocket(handle, Int32(bitPattern: 0x8004_667E), &nonBlocking)   // FIONBIO
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 { return true }
        guard WSAGetLastError() == WSAEWOULDBLOCK else { return false }
        var writable = fd_set()
        writable.fd_count = 1
        writable.fd_array.0 = handle
        var failed = fd_set()
        failed.fd_count = 1
        failed.fd_array.0 = handle
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        guard select(0, nil, &writable, &failed, &wait) > 0 else { return false }
        return writable.fd_count > 0 && failed.fd_count == 0
    }

    /// Tries to create a file at `path`, as a decoder that was exploited might plant or overwrite one.
    static func writes(toFile path: String) -> Bool {
        let handle = CreateFileW(path.wide, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        guard let handle, handle != INVALID_HANDLE_VALUE else { return false }
        CloseHandle(handle)
        DeleteFileW(path.wide)
        return true
    }

    /// Tries to open another process (by id) to read its memory, as an exploited decoder might the helper that holds the index.
    static func opensProcess(_ pid: Int) -> Bool {
        guard let handle = OpenProcess(DWORD(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION), false, DWORD(pid)) else { return false }
        CloseHandle(handle)
        return true
    }

    /// Tries to write to the user's registry hive (a way to be started again at the next sign-in).
    static func writesRegistry() -> Bool {
        let name = "Software\\DigUpSandboxProbe-\(UUID().uuidString)"
        var key: HKEY?
        let keyWrite = REGSAM(0x0002_0006)
        guard RegCreateKeyExW(HKEY_CURRENT_USER, name.wide, 0, nil, 0, keyWrite, nil, &key, nil) == ERROR_SUCCESS
        else { return false }
        RegCloseKey(key)
        RegDeleteKeyW(HKEY_CURRENT_USER, name.wide)
        return true
    }

    /// Tries to connect to a named pipe (another program's way of taking requests: a service, a password manager, the helper's own).
    static func connects(toPipe name: String) -> Bool {
        let handle = CreateFileW(name.wide, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
        guard let handle, handle != INVALID_HANDLE_VALUE else { return false }
        CloseHandle(handle)
        return true
    }

    /// Tries to open a named shared-memory object that another process made (a Global or Local name in the session's namespace).
    static func opensSharedMemory(named name: String) -> Bool {
        guard let handle = OpenFileMappingW(DWORD(FILE_MAP_READ), false, name.wide) else { return false }
        CloseHandle(handle)
        return true
    }

    /// Tries to start another program, as an exploited decoder might.
    static func spawnsAChild() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        process.arguments = ["/c", "exit", "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return true
    }
}
#endif
