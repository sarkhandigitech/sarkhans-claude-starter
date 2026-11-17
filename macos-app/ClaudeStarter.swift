import AppKit
import Security
import SwiftUI

struct Project: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    var installedVersion: String?
    var stacks: [String]
    var catalogInstalled: Set<String>
    var phase: String?
    var designMode: String?
    var kickoffDone: Bool
    var responseLanguage: String?
    var hasFrontend: Bool
    var usesReact: Bool

    var id: String { path }
    var isInstalled: Bool { installedVersion != nil }
    var isDesignLocked: Bool { (designMode ?? (phase == "new" ? "open" : "locked")) == "locked" }
}

struct CatalogItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let category: String
    let name: String
    let description: String
    let skill: String?
    let recommended: String?
    let path: String?
    let repo: String?

    var isMine: Bool { category == CatalogItem.mySkills }
    static let mySkills = "My skills"
}

struct BuiltinSkill: Identifiable, Hashable {
    let id: String
    let summary: String
}

struct SkillChoice: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    var id: String { name }
}

enum RegisterOutcome {
    case added(String)
    case choices([SkillChoice])
    case failed(String)
}

enum InstallState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

enum Shell {
    private static let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 180, extraPath: String? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = extraPath.map { "\($0):\(Shell.basePath)" } ?? Shell.basePath
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func runAsync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 180, extraPath: String? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Shell.run(executable, arguments, timeout: timeout, extraPath: extraPath))
            }
        }
    }
}

enum NodeLocator {
    static func find() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        let shellResult = Shell.run("/bin/zsh", ["-lc", "command -v node"], timeout: 8)
        if shellResult.succeeded,
           let lastLine = shellResult.output.split(separator: "\n").last {
            let candidate = String(lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }

        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
            "\(home)/.local/share/mise/shims/node",
        ]
        candidates.append(contentsOf: versionedBinaries(root: "\(home)/.nvm/versions/node", suffix: "bin/node"))
        candidates.append(contentsOf: versionedBinaries(root: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin/node"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func versionedBinaries(root: String, suffix: String) -> [String] {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/\(suffix)" }
    }
}

enum GitLocator {
    static func isAvailable() -> Bool {
        let fileManager = FileManager.default
        if ["/opt/homebrew/bin/git", "/usr/local/bin/git"].contains(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return true
        }
        if Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 8).succeeded {
            return true
        }
        let result = Shell.run("/bin/zsh", ["-lc", "command -v git"], timeout: 8)
        let path = result.output
            .split(separator: "\n")
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return result.succeeded && !path.isEmpty && path != "/usr/bin/git"
    }
}

enum NodeInstaller {
    private struct Release: Decodable {
        let version: String
        let files: [String]
        let isLTS: Bool

        enum CodingKeys: String, CodingKey { case version, files, lts }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(String.self, forKey: .version)
            files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
            isLTS = (try? container.decode(String.self, forKey: .lts)) != nil
        }
    }

    static func downloadLatestLTS() async throws -> URL {
        guard let indexURL = URL(string: "https://nodejs.org/dist/index.json") else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: indexURL)
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let release = releases.first(where: { $0.isLTS && $0.files.contains("osx-x64-pkg") }),
              let packageURL = URL(string: "https://nodejs.org/dist/\(release.version)/node-\(release.version).pkg")
        else { throw URLError(.resourceUnavailable) }

        let (downloaded, response) = try await URLSession.shared.download(from: packageURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("node-\(release.version).pkg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: downloaded, to: target)
        return target
    }
}

enum ProjectFilter: String, CaseIterable, Identifiable {
    case needsSetup
    case ready
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsSetup: return "Needs setup"
        case .ready: return "Ready"
        case .all: return "All"
        }
    }
}

enum ProjectStatus {
    case notSetUp
    case updateAvailable
    case ready
}

enum DisplayStatus {
    case notSetUp
    case updateAvailable
    case ready
    case working
    case failed

    var title: String {
        switch self {
        case .notSetUp: return "Not set up"
        case .updateAvailable: return "Update available"
        case .ready: return "Ready"
        case .working: return "Working…"
        case .failed: return "Didn’t finish"
        }
    }

    var icon: String {
        switch self {
        case .notSetUp: return "circle.dashed"
        case .updateAvailable: return "arrow.up.circle.fill"
        case .ready: return "checkmark.circle.fill"
        case .working: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .notSetUp: return .secondary
        case .updateAvailable: return .orange
        case .ready: return .green
        case .working: return .blue
        case .failed: return .red
        }
    }
}

enum JobKind {
    case setUp
    case repair
    case remove
    case setting
}

private final class JobBatch {
    let kind: JobKind
    let targets: [Project]
    var remaining: Int
    var failed: [Project] = []

    init(kind: JobKind, targets: [Project]) {
        self.kind = kind
        self.targets = targets
        remaining = targets.count
    }
}

private struct Job {
    let project: Project
    let steps: [[String]]
    let batch: JobBatch
    let key: String?
}

struct Notice: Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
}

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Sarkhans Claude Starter"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

struct ReleaseInfo: Equatable {
    let version: String
    let notes: String
    let pageURL: URL
    let downloadURL: URL
    let assetAPIURL: URL
    let token: String?
}

enum UpdateError: LocalizedError {
    case notConfigured
    case notFound(String)
    case http(Int)
    case noAsset
    case invalidBundle(String)
    case translocated
    case cancelled
    case adminFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren’t set up in this build."
        case .notFound(let repo): return "No release found on github.com/\(repo). If the repository is private, add a GitHub token in Settings."
        case .http(let code): return "GitHub answered with HTTP \(code). Try again later."
        case .noAsset: return "The latest release has no app download (.zip)."
        case .invalidBundle(let reason): return "The downloaded app didn’t pass a check: \(reason)."
        case .translocated: return "Open the app from your Applications folder, not from the downloaded installer, then update."
        case .cancelled: return "Update cancelled."
        case .adminFailed(let reason): return "The update couldn’t be installed: \(reason)"
        }
    }
}

enum GitHubToken {
    private static let service = "SarkhansClaudeStarter.github"
    private static let account = "token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func stored() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ token: String) {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func resolve() -> String? {
        if let token = stored() { return token }
        let result = Shell.run("/bin/zsh", ["-lc", "command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null"], timeout: 8)
        let token = result.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return result.succeeded && !token.isEmpty && !token.contains(" ") ? token : nil
    }
}

private final class StripAuthorizationOnRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var next = request
        if next.url?.host != task.originalRequest?.url?.host {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

struct PreparedUpdate: Sendable {
    let script: URL
    let adminCommand: String?
}

enum Updater {
    static let repository: String? = Bundle.main.path(forResource: "update-repo", ofType: "txt")
        .flatMap(StarterModel.readTrimmed)
        .flatMap { $0.contains("/") ? $0 : nil }

    private struct Release: Decodable {
        let tagName: String
        let body: String?
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let url: URL
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url
            case browserDownloadURL = "browser_download_url"
        }
    }

    static func latestRelease() async throws -> ReleaseInfo {
        guard let repo = repository, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.notConfigured
        }
        var token: String?
        var (status, data) = try await get(url, token: nil)
        if [401, 403, 404].contains(status) {
            token = await Task.detached(priority: .utility) { GitHubToken.resolve() }.value
            if let token {
                (status, data) = try await get(url, token: token)
            }
        }
        if status == 404 { throw UpdateError.notFound(repo) }
        guard status == 200 else { throw UpdateError.http(status) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw UpdateError.noAsset }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return ReleaseInfo(
            version: version,
            notes: release.body ?? "",
            pageURL: release.htmlURL,
            downloadURL: asset.browserDownloadURL,
            assetAPIURL: asset.url,
            token: token
        )
    }

    private static func get(_ url: URL, token: String?) async throws -> (Int, Data) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SarkhansClaudeStarter/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func download(_ release: ReleaseInfo) async throws -> URL {
        var request = URLRequest(url: release.token == nil ? release.downloadURL : release.assetAPIURL)
        request.timeoutInterval = 120
        request.setValue("SarkhansClaudeStarter/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let token = release.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        }
        let (file, response) = try await URLSession.shared.download(for: request, delegate: StripAuthorizationOnRedirect())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.http(status) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("SarkhansClaudeStarter-\(release.version).zip")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    static func prepareInstall(zip: URL) throws -> PreparedUpdate {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("SarkhansUpdate-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120).succeeded else {
            throw UpdateError.invalidBundle("the download couldn’t be unpacked")
        }
        let contents = (try? fileManager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.invalidBundle("no app inside the download")
        }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("it’s a different app")
        }
        guard Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path], timeout: 60).succeeded else {
            throw UpdateError.invalidBundle("its signature is broken")
        }
        let current = Bundle.main.bundleURL
        if current.path.contains("/AppTranslocation/") {
            throw UpdateError.translocated
        }
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], timeout: 30)
        let target = shellQuote(current.path)
        let backup = shellQuote(current.path + ".old")
        let replacement = shellQuote(newApp.path)
        let swap = "/bin/rm -rf \(backup); /bin/mv \(target) \(backup) && { /bin/mv \(replacement) \(target) || { /bin/mv \(backup) \(target); exit 1; }; } && /bin/rm -rf \(backup)"
        let parent = current.deletingLastPathComponent()
        let writable = fileManager.isWritableFile(atPath: parent.path) && fileManager.isWritableFile(atPath: current.path)
        let script = work.appendingPathComponent("install.sh")
        let text = """
        #!/bin/bash
        PID=\(ProcessInfo.processInfo.processIdentifier)
        for _ in $(/usr/bin/seq 1 50); do /bin/kill -0 $PID 2>/dev/null || break; /bin/sleep 0.2; done
        /bin/kill $PID 2>/dev/null
        for _ in $(/usr/bin/seq 1 25); do /bin/kill -0 $PID 2>/dev/null || break; /bin/sleep 0.2; done
        /bin/kill -9 $PID 2>/dev/null
        /bin/sleep 0.3
        \(writable ? swap : ":")
        /usr/bin/open \(target)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        return PreparedUpdate(script: script, adminCommand: writable ? nil : swap)
    }

    @MainActor
    static func runWithAdministratorPrivileges(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "\(AppInfo.name) needs your password to install the update."
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw UpdateError.adminFailed("couldn’t ask for permission")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                throw UpdateError.cancelled
            }
            throw UpdateError.adminFailed(error[NSAppleScript.errorMessage] as? String ?? "unknown error")
        }
    }

    static func launch(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        try process.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class StarterModel: ObservableObject {
    static let appVersion = AppInfo.version

    @Published private(set) var projects: [Project] = []
    @Published private(set) var states: [String: InstallState] = [:]
    @Published private(set) var log = ""
    @Published private(set) var nodePath: String?
    @Published private(set) var gitAvailable = true
    @Published private(set) var isInstallingNode = false
    @Published private(set) var starterVersion: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var catalog: [CatalogItem] = []
    @Published private(set) var builtinSkills: [BuiltinSkill] = []
    @Published private(set) var notice: Notice?
    @Published private(set) var isProcessing = false
    @Published private(set) var availableUpdate: ReleaseInfo?
    @Published private(set) var updateStatus: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var updatePhase = ""
    @Published var showingUpdate = false
    @Published private(set) var pendingKeys: Set<String> = []
    @Published private(set) var hasChosenFolder = UserDefaults.standard.string(forKey: "projectsFolder") != nil
    @Published var selection: Set<String> = []
    @Published var filter: ProjectFilter = .needsSetup
    @Published var searchText = ""
    @Published var showingActivity = false
    @Published var languageChoices: [String: String] = [:]
    @Published var defaultLanguage: String = UserDefaults.standard.string(forKey: "responseLanguage") ?? "English" {
        didSet { UserDefaults.standard.set(defaultLanguage, forKey: "responseLanguage") }
    }

    static let languages = [
        "English", "Azerbaijani", "Turkish", "Russian", "Ukrainian", "German", "French", "Spanish",
        "Italian", "Portuguese", "Dutch", "Polish", "Arabic", "Persian", "Chinese", "Japanese", "Korean",
    ]

    let home: String
    @Published private(set) var wwwPath: String
    let starterPath: String
    private let fileManager = FileManager.default
    private var didApplyInitialFilter = false
    private var noticeTask: Task<Void, Never>?
    private var queue: [Job] = []
    private var checkedForUpdates = false

    init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        wwwPath = UserDefaults.standard.string(forKey: "projectsFolder") ?? home + "/www"
        starterPath = home + "/claude-web-starter"
    }

    var installerPath: String { starterPath + "/install.mjs" }
    var userCatalogPath: String { home + "/.claude-starter/my-skills.json" }
    var isBusy: Bool { isProcessing }
    var canRun: Bool { nodePath != nil && starterVersion != nil }
    var canFinishSetup: Bool { nodePath != nil && starterVersion != nil }
    var isReadyToUse: Bool { canFinishSetup && hasChosenFolder }

    var visibleProjects: [Project] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return projects.filter { project in
            matches(project, filter) && (query.isEmpty || project.name.localizedCaseInsensitiveContains(query))
        }
    }

    var selectedProjects: [Project] { projects.filter { selection.contains($0.id) } }
    var needsSetupProjects: [Project] { projects.filter { status(of: $0) != .ready } }

    var projectsFolderDisplay: String {
        wwwPath.hasPrefix(home) ? "~" + String(wwwPath.dropFirst(home.count)) : wwwPath
    }

    private var bundledZip: String? {
        Bundle.main.path(forResource: "claude-web-starter", ofType: "zip")
    }

    private var bundledVersion: String? {
        Bundle.main.path(forResource: "starter-version", ofType: "txt").flatMap(Self.readTrimmed)
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        await ensureStarter()
        loadCatalog()
        nodePath = await Task.detached(priority: .userInitiated) { NodeLocator.find() }.value
        gitAvailable = await Task.detached(priority: .userInitiated) { GitLocator.isAvailable() }.value
        refresh()
        if !didApplyInitialFilter {
            didApplyInitialFilter = true
            filter = needsSetupProjects.isEmpty ? .all : .needsSetup
        }
        isLoading = false
        hasLoaded = true
        if !checkedForUpdates {
            checkedForUpdates = true
            Task { await checkForUpdates(userInitiated: false) }
        }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard Updater.repository != nil else {
            updateStatus = UpdateError.notConfigured.errorDescription
            return
        }
        if userInitiated { updateStatus = "Checking…" }
        do {
            let release = try await Updater.latestRelease()
            if Self.isOlder(AppInfo.version, than: release.version) {
                availableUpdate = release
                updateStatus = "Version \(release.version) is available."
                if userInitiated { showingUpdate = true }
            } else {
                availableUpdate = nil
                updateStatus = "You’re up to date (\(AppInfo.version))."
                if userInitiated { showNotice("You’re up to date", isError: false) }
            }
        } catch {
            updateStatus = error.localizedDescription
            if userInitiated { showNotice(error.localizedDescription, isError: true) }
        }
    }

    func installUpdate() async {
        guard let release = availableUpdate, !isUpdating else { return }
        guard !isProcessing else {
            showNotice("Wait until the current work finishes, then update", isError: true)
            return
        }
        isUpdating = true
        do {
            setUpdatePhase("Downloading \(release.version)…")
            let zip = try await Updater.download(release)
            setUpdatePhase("Checking the download…")
            let prepared = try await Task.detached(priority: .userInitiated) { try Updater.prepareInstall(zip: zip) }.value
            if let command = prepared.adminCommand {
                setUpdatePhase("Waiting for your password…")
                try Updater.runWithAdministratorPrivileges(command)
            }
            setUpdatePhase("Restarting…")
            try Updater.launch(prepared.script)
            showingUpdate = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            exit(0)
        } catch UpdateError.cancelled {
            isUpdating = false
            showNotice("Update cancelled", isError: false)
        } catch {
            isUpdating = false
            log += "✖ Update failed: \(error.localizedDescription)\n\n"
            showNotice("Update failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func setUpdatePhase(_ phase: String) {
        updatePhase = phase
        log += "… Update: \(phase)\n\n"
    }

    func openReleasePage() {
        if let url = availableUpdate?.pageURL {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        let names = (try? fileManager.contentsOfDirectory(atPath: wwwPath)) ?? []
        projects = names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { self.makeProject(named: $0) }
        selection.formIntersection(projects.map(\.id))
    }

    func status(of project: Project) -> ProjectStatus {
        guard let installed = project.installedVersion else { return .notSetUp }
        if let latest = starterVersion, Self.isOlder(installed, than: latest) { return .updateAvailable }
        return .ready
    }

    func displayStatus(of project: Project) -> DisplayStatus {
        if states[project.id] == .running { return .working }
        if states[project.id] == .failed { return .failed }
        switch status(of: project) {
        case .notSetUp: return .notSetUp
        case .updateAvailable: return .updateAvailable
        case .ready: return .ready
        }
    }

    func isRunning(_ project: Project) -> Bool {
        states[project.id] == .running
    }

    func count(in filter: ProjectFilter) -> Int {
        projects.filter { matches($0, filter) }.count
    }

    func count(status: ProjectStatus) -> Int {
        projects.filter { self.status(of: $0) == status }.count
    }

    private func matches(_ project: Project, _ filter: ProjectFilter) -> Bool {
        switch filter {
        case .needsSetup: return status(of: project) != .ready
        case .ready: return status(of: project) == .ready
        case .all: return true
        }
    }

    func pruneSelection() {
        selection.formIntersection(visibleProjects.map(\.id))
    }

    func project(withID id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func language(for project: Project) -> String {
        project.responseLanguage ?? languageChoices[project.id] ?? defaultLanguage
    }

    func setUpTitle(for targets: [Project]) -> String {
        let newCount = targets.filter { status(of: $0) == .notSetUp }.count
        let updateCount = targets.filter { status(of: $0) == .updateAvailable }.count
        if newCount > 0 && updateCount > 0 { return "Set up \(newCount) and update \(updateCount)" }
        if newCount > 0 { return newCount == 1 ? "Set up 1 project" : "Set up \(newCount) projects" }
        return updateCount == 1 ? "Update 1 project" : "Update \(updateCount) projects"
    }

    func setUp(_ targets: [Project]) {
        let idle = targets.filter { !isRunning($0) }
        enqueue(idle.map { ($0, [installArguments(for: $0)]) }, kind: .setUp)
    }

    func repair(_ targets: [Project]) {
        let installed = targets.filter { $0.isInstalled && !isRunning($0) }
        guard !installed.isEmpty, confirmRepair(installed) else { return }
        enqueue(installed.map { project -> (Project, [[String]]) in
            let reinstall = [project.path, "--no-recommended", "--language", language(for: project)]
            let skills = project.catalogInstalled.sorted().map { [project.path, "--add-skill", $0] }
            return (project, [[project.path, "--uninstall"], reinstall] + skills)
        }, kind: .repair)
    }

    func remove(_ targets: [Project]) {
        let installed = targets.filter { $0.isInstalled && !isRunning($0) }
        guard !installed.isEmpty, confirmRemove(installed) else { return }
        enqueue(installed.map { ($0, [[$0.path, "--uninstall"]]) }, kind: .remove)
    }

    func setDesignLocked(_ locked: Bool, for targets: [Project]) {
        let mode = locked ? "locked" : "open"
        let changed = targets.filter { $0.isInstalled && $0.isDesignLocked != locked }
        mutate(changed) { $0.designMode = mode }
        enqueue(changed.map { ($0, [[$0.path, "--design", mode]]) }, kind: .setting) { "\($0.id)|design" }
    }

    func setPhase(_ phase: String, for targets: [Project]) {
        let changed = targets.filter { $0.isInstalled && $0.phase != phase }
        mutate(changed) { $0.phase = phase }
        enqueue(changed.map { ($0, [[$0.path, "--phase", phase]]) }, kind: .setting) { "\($0.id)|phase" }
    }

    func setLanguage(_ language: String, for targets: [Project]) {
        for project in targets where !project.isInstalled {
            languageChoices[project.id] = language
        }
        let changed = targets.filter { $0.isInstalled && $0.responseLanguage != language }
        mutate(changed) { $0.responseLanguage = language }
        enqueue(changed.map { ($0, [[$0.path, "--language", language]]) }, kind: .setting) { "\($0.id)|language" }
    }

    func setCatalogItem(_ item: CatalogItem, enabled: Bool, for targets: [Project]) {
        let changed = targets.filter { $0.isInstalled && $0.catalogInstalled.contains(item.id) != enabled }
        mutate(changed) { project in
            if enabled {
                project.catalogInstalled.insert(item.id)
            } else {
                project.catalogInstalled.remove(item.id)
            }
        }
        let flag = enabled ? "--add-skill" : "--remove-skill"
        enqueue(changed.map { ($0, [[$0.path, flag, item.id]]) }, kind: .setting) { "\($0.id)|\(item.id)" }
    }

    func isPending(_ item: CatalogItem, for project: Project) -> Bool {
        pendingKeys.contains("\(project.id)|\(item.id)")
    }

    func isRecommended(_ item: CatalogItem, for project: Project) -> Bool {
        switch item.recommended ?? "" {
        case "all": return true
        case "frontend": return project.hasFrontend
        case "react": return project.usesReact
        default: return false
        }
    }

    func recommendedItems(for project: Project) -> [CatalogItem] {
        catalog.filter { isRecommended($0, for: project) }
    }

    func otherItems(in category: String, for project: Project) -> [CatalogItem] {
        catalog.filter { $0.category == category && !isRecommended($0, for: project) }
    }

    func turnOnRecommended(for project: Project) {
        for item in recommendedItems(for: project) where !project.catalogInstalled.contains(item.id) {
            setCatalogItem(item, enabled: true, for: [project])
        }
    }

    var mySkills: [CatalogItem] { catalog.filter(\.isMine) }

    func registerSkill(source: String, pick: String?) async -> RegisterOutcome {
        guard let node = nodePath else { return .failed("Node.js is missing. Install it first.") }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = [installerPath, "--register-skill", trimmed]
        if let pick { arguments += ["--pick", pick] }
        let result = await Shell.runAsync(node, arguments, extraPath: (node as NSString).deletingLastPathComponent)
        if result.status == 3,
           let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
           let payload = try? JSONDecoder().decode([String: [SkillChoice]].self, from: Data(line.utf8)),
           let choices = payload["choices"], !choices.isEmpty {
            return .choices(choices)
        }
        appendLog(title: "Add skill \(trimmed)\(pick.map { " (\($0))" } ?? "")", result: result)
        guard result.succeeded else {
            let message = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("✖") }
                .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return .failed(message ?? "Couldn’t add the skill. See Activity for details.")
        }
        loadCatalog()
        let name = pick ?? catalog.last(where: \.isMine)?.name ?? "Skill"
        showNotice("\(name) added to your skills", isError: false)
        return .added(name)
    }

    func unregisterSkill(_ item: CatalogItem) {
        guard let node = nodePath, item.isMine else { return }
        guard confirm(
            title: "Remove “\(item.name)” from your skills?",
            message: "It disappears from the list. Projects that already have it keep their copy until you switch it off there first.",
            action: "Remove"
        ) else { return }
        Task {
            let result = await Shell.runAsync(node, [installerPath, "--unregister-skill", item.id], extraPath: (node as NSString).deletingLastPathComponent)
            appendLog(title: "Remove skill \(item.id)", result: result)
            loadCatalog()
            showNotice(result.succeeded ? "\(item.name) removed from your skills" : "Couldn’t remove \(item.name)", isError: !result.succeeded)
        }
    }

    var catalogCategories: [String] {
        var seen: [String] = []
        for item in catalog where !seen.contains(item.category) {
            seen.append(item.category)
        }
        return seen
    }

    func catalogItems(in category: String) -> [CatalogItem] {
        catalog.filter { $0.category == category }
    }

    static func categoryTitle(_ category: String) -> String {
        switch category {
        case "UI/UX": return "Design skills"
        case "Frontend": return "Frontend skills"
        case "MCP": return "Tools for Claude"
        default: return category
        }
    }

    func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that contains your projects"
        panel.directoryURL = URL(fileURLWithPath: wwwPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        wwwPath = url.path
        UserDefaults.standard.set(url.path, forKey: "projectsFolder")
        selection.removeAll()
        refresh()
        filter = needsSetupProjects.isEmpty ? .all : .needsSetup
    }

    func confirmProjectsFolder() {
        UserDefaults.standard.set(wwwPath, forKey: "projectsFolder")
        hasChosenFolder = true
    }

    func reveal(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func revealProjectsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wwwPath)])
    }

    func clearLog() {
        log = ""
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    func installNode() async {
        guard !isInstallingNode else { return }
        isInstallingNode = true
        defer { isInstallingNode = false }
        log += "… Downloading the latest Node.js LTS installer from nodejs.org\n\n"
        do {
            let package = try await NodeInstaller.downloadLatestLTS()
            log += "✔ Downloaded \(package.lastPathComponent)\n\n"
            NSWorkspace.shared.open(package)
            showNotice("Finish the Node.js installer, then come back here", isError: false)
        } catch {
            log += "✖ Node.js download failed: \(error.localizedDescription)\n\n"
            showNotice("Couldn’t download Node.js. Install the LTS version from nodejs.org.", isError: true)
        }
    }

    func installCommandLineTools() {
        _ = Shell.run("/usr/bin/xcode-select", ["--install"], timeout: 15)
        log += "… Asked macOS to install the Command Line Tools (includes Git)\n\n"
        showNotice("Finish the macOS installer window, then come back here", isError: false)
    }

    private func mutate(_ targets: [Project], _ change: (inout Project) -> Void) {
        let ids = Set(targets.map(\.id))
        for index in projects.indices where ids.contains(projects[index].id) {
            change(&projects[index])
        }
    }

    private func installArguments(for project: Project, forceUpdate: Bool = true) -> [String] {
        if forceUpdate && project.isInstalled {
            return [project.path, "--force"]
        }
        return [project.path, "--language", language(for: project)]
    }

    private func enqueue(_ jobs: [(Project, [[String]])], kind: JobKind, key: ((Project) -> String)? = nil) {
        guard nodePath != nil, starterVersion != nil, !jobs.isEmpty else { return }
        let batch = JobBatch(kind: kind, targets: jobs.map { $0.0 })
        for (project, steps) in jobs {
            let jobKey = key?(project)
            if let jobKey { pendingKeys.insert(jobKey) }
            if kind != .setting { states[project.id] = .running }
            queue.append(Job(project: project, steps: steps, batch: batch, key: jobKey))
        }
        processQueue()
    }

    private func processQueue() {
        guard !isProcessing, let node = nodePath else { return }
        isProcessing = true
        let installer = installerPath
        let nodeDirectory = (node as NSString).deletingLastPathComponent

        Task { [self] in
            while !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                var succeeded = true
                for step in job.steps where succeeded {
                    let result = await Shell.runAsync(node, [installer] + step, extraPath: nodeDirectory)
                    let flags = step.dropFirst().joined(separator: " ")
                    self.appendLog(title: flags.isEmpty ? job.project.name : "\(job.project.name) \(flags)", result: result)
                    succeeded = result.succeeded
                }
                if let key = job.key { self.pendingKeys.remove(key) }
                if job.batch.kind != .setting {
                    self.states[job.project.id] = succeeded ? .succeeded : .failed
                } else if !succeeded {
                    self.states[job.project.id] = .failed
                }
                if !succeeded { job.batch.failed.append(job.project) }
                job.batch.remaining -= 1
                if !self.queue.contains(where: { $0.project.id == job.project.id }) {
                    self.reloadProject(job.project.id)
                }
                if job.batch.remaining == 0 {
                    self.announce(kind: job.batch.kind, targets: job.batch.targets, failed: job.batch.failed)
                }
            }
            self.isProcessing = false
        }
    }

    private func reloadProject(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        if let fresh = makeProject(named: projects[index].name) {
            projects[index] = fresh
        } else {
            projects.remove(at: index)
        }
    }

    private func announce(kind: JobKind, targets: [Project], failed: [Project]) {
        if let first = failed.first {
            let text = targets.count == 1
                ? "\(first.name): something went wrong"
                : "\(failed.count) of \(targets.count) projects didn’t finish"
            showNotice(text, isError: true)
            return
        }
        let single = targets.count == 1 ? targets[0].name : nil
        let text: String
        switch kind {
        case .setUp: text = single.map { "\($0) is ready" } ?? "\(targets.count) projects are ready"
        case .repair: text = single.map { "\($0) repaired" } ?? "\(targets.count) projects repaired"
        case .remove: text = single.map { "Removed from \($0)" } ?? "Removed from \(targets.count) projects"
        case .setting: return
        }
        showNotice(text, isError: false)
    }

    private func showNotice(_ text: String, isError: Bool) {
        noticeTask?.cancel()
        notice = Notice(text: text, isError: isError)
        guard !isError else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func confirmRemove(_ targets: [Project]) -> Bool {
        confirm(
            title: targets.count == 1 ? "Remove \(AppInfo.name) from “\(targets[0].name)”?" : "Remove \(AppInfo.name) from \(targets.count) projects?",
            message: "\(Self.nameList(targets))\n\nRules, hooks and skills are removed. CLAUDE.md is kept as CLAUDE.md.bak. Your code isn’t touched.",
            action: "Remove"
        )
    }

    private func confirmRepair(_ targets: [Project]) -> Bool {
        confirm(
            title: targets.count == 1 ? "Repair “\(targets[0].name)”?" : "Repair \(targets.count) projects?",
            message: "\(Self.nameList(targets))\n\nEverything is removed and set up again from scratch. CLAUDE.md is kept as CLAUDE.md.bak.",
            action: "Repair"
        )
    }

    private func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func loadCatalog() {
        var items: [CatalogItem] = []
        if let data = fileManager.contents(atPath: starterPath + "/skills-catalog.json"),
           let builtin = try? JSONDecoder().decode([CatalogItem].self, from: data) {
            items = builtin
        }
        if let data = fileManager.contents(atPath: userCatalogPath),
           let mine = try? JSONDecoder().decode([CatalogItem].self, from: data) {
            let known = Set(items.map(\.id))
            items += mine.filter { !known.contains($0.id) && $0.isMine }
        }
        catalog = items
        loadBuiltinSkills()
    }

    private func loadBuiltinSkills() {
        let directory = starterPath + "/template/.claude/skills"
        let names = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        builtinSkills = names.sorted().compactMap { name in
            guard let text = try? String(contentsOfFile: "\(directory)/\(name)/SKILL.md", encoding: .utf8) else { return nil }
            return BuiltinSkill(id: name, summary: Self.firstSentence(Self.frontmatterValue(text, key: "description")))
        }
    }

    nonisolated static func frontmatterValue(_ text: String, key: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) where line.hasPrefix("\(key):") {
            return String(line.dropFirst(key.count + 1))
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
    }

    nonisolated static func firstSentence(_ text: String) -> String {
        guard let range = text.range(of: ". ") else { return text }
        return String(text[..<range.lowerBound]) + "."
    }

    private func ensureStarter() async {
        let installed = Self.readTrimmed(starterPath + "/VERSION")
        if let zip = bundledZip, let bundled = bundledVersion, Self.isOlder(installed, than: bundled) {
            if fileManager.fileExists(atPath: starterPath) {
                try? fileManager.removeItem(atPath: starterPath)
            }
            let result = await Shell.runAsync("/usr/bin/unzip", ["-oq", zip, "-d", home])
            appendLog(title: "Rules v\(bundled) → \(starterPath)", result: result)
        }
        let hasInstaller = fileManager.fileExists(atPath: installerPath)
        starterVersion = hasInstaller ? Self.readTrimmed(starterPath + "/VERSION") ?? "?" : nil
    }

    private static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func installedCatalogIDs(at path: String) -> Set<String> {
        var mcpServers: [String: Any] = [:]
        if let json = Self.readJSONObject(path + "/.mcp.json"),
           let servers = json["mcpServers"] as? [String: Any] {
            mcpServers = servers
        }
        var installed = Set<String>()
        for item in catalog {
            if item.type == "mcp" {
                if mcpServers[item.id] != nil { installed.insert(item.id) }
            } else if let skill = item.skill, fileManager.fileExists(atPath: "\(path)/.claude/skills/\(skill)/.catalog-source") {
                installed.insert(item.id)
            }
        }
        return installed
    }

    private func makeProject(named name: String) -> Project? {
        let path = wwwPath + "/" + name
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }

        let stacks = Self.stackMarkers
            .filter { marker in marker.files.contains { self.fileManager.fileExists(atPath: path + "/" + $0) } }
            .map { $0.label }
        guard !stacks.isEmpty else { return nil }

        let marker = Self.readTrimmed(path + "/.claude/starter-version")
        let legacy = fileManager.fileExists(atPath: path + "/.claude/hooks/guard-bash.mjs") ? "1.0" : nil
        let config = Self.readJSONObject(path + "/.claude/hooks/config.json")
        let packageJSON = Self.readJSONObject(path + "/package.json")
        let dependencies = (packageJSON?["dependencies"] as? [String: Any] ?? [:])
            .merging(packageJSON?["devDependencies"] as? [String: Any] ?? [:]) { first, _ in first }
        return Project(
            path: path,
            name: name,
            installedVersion: marker ?? legacy,
            stacks: stacks,
            catalogInstalled: installedCatalogIDs(at: path),
            phase: config?["projectPhase"] as? String,
            designMode: config?["designMode"] as? String,
            kickoffDone: fileManager.fileExists(atPath: path + "/.claude/KICKOFF.md"),
            responseLanguage: config?["responseLanguage"] as? String,
            hasFrontend: packageJSON != nil,
            usesReact: dependencies["react"] != nil || dependencies["next"] != nil
        )
    }

    private func appendLog(title: String, result: CommandResult) {
        let mark = result.succeeded ? "✔" : "✖"
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        log += "\(mark) \(title)\n\(output)\n\n"
    }

    private static let stackMarkers: [(label: String, files: [String])] = [
        ("PHP", ["composer.json"]),
        ("Go", ["go.mod"]),
        ("Python", ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "manage.py"]),
        ("Node", ["package.json"]),
    ]

    private static func nameList(_ targets: [Project]) -> String {
        let names = targets.prefix(12).map { "• \($0.name)" }
        let more = targets.count > 12 ? ["… and \(targets.count - 12) more"] : []
        return (names + more).joined(separator: "\n")
    }

    nonisolated static func readTrimmed(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func isOlder(_ version: String?, than other: String) -> Bool {
        guard let version else { return true }
        return version.compare(other, options: .numeric) == .orderedAscending
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ClaudeStarterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = StarterModel()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.checkForUpdates(userInitiated: true) }
                }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Getting ready…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isReadyToUse {
                SetupView()
            } else {
                MainView()
            }
        }
        .task { await model.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard model.hasLoaded, !model.isBusy, !model.isInstallingNode else { return }
            if !model.canFinishSetup || !model.gitAvailable {
                Task { await model.start() }
            }
        }
        .sheet(isPresented: $model.showingActivity) {
            ActivityView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingUpdate) {
            UpdateSheet()
                .environmentObject(model)
        }
    }
}

@MainActor
struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

enum StepState {
    case done
    case needed
    case optional
}

@MainActor
struct SetupStep<Accessory: View>: View {
    let title: String
    let detail: String
    let state: StepState
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var icon: String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .needed: return "exclamationmark.circle.fill"
        case .optional: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .done: return .green
        case .needed: return .orange
        case .optional: return .blue
        }
    }
}

@MainActor
struct SetupView: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    AppIconView(size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to \(AppInfo.name)")
                            .font(.largeTitle.weight(.semibold))
                        Text("Let’s check a few things before you set up your projects.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    if model.starterVersion == nil {
                        SetupStep(
                            title: "Starter files",
                            detail: "The rules couldn’t be unpacked into ~/claude-web-starter. Try again, or reinstall the app.",
                            state: .needed
                        ) {
                            Button("Try again") { Task { await model.start() } }
                        }
                        Divider()
                    }
                    SetupStep(
                        title: "Node.js",
                        detail: model.nodePath.map { "Installed at \($0)" } ?? "Needed to set up projects. Installs the official version from nodejs.org.",
                        state: model.nodePath == nil ? .needed : .done
                    ) {
                        if model.nodePath == nil {
                            if model.isInstallingNode {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Install Node.js") { Task { await model.installNode() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    Divider()
                    SetupStep(
                        title: "Git",
                        detail: model.gitAvailable ? "Installed" : "Recommended. Needed for design skills and by Claude Code. Installs Apple’s Command Line Tools.",
                        state: model.gitAvailable ? .done : .optional
                    ) {
                        if !model.gitAvailable {
                            Button("Install Git") { model.installCommandLineTools() }
                        }
                    }
                    Divider()
                    SetupStep(
                        title: "Projects folder",
                        detail: folderDetail,
                        state: model.projects.isEmpty ? .needed : .done
                    ) {
                        Button("Choose…") { model.chooseProjectsFolder() }
                    }
                    Divider()
                    SetupStep(
                        title: "Claude’s language",
                        detail: "Claude explains, asks and reports in this language. Code, commits and pull requests stay in English.",
                        state: .done
                    ) {
                        Picker("Language", selection: $model.defaultLanguage) {
                            ForEach(StarterModel.languages, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))

                HStack {
                    Text("You can change all of this later in Settings (⌘,).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.confirmProjectsFolder()
                    } label: {
                        Text("Continue")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFinishSetup)
                }
            }
            .frame(maxWidth: 620)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private var folderDetail: String {
        let count = model.projects.count
        if count == 0 {
            return "No projects found in \(model.projectsFolderDisplay). Choose the folder that contains your projects."
        }
        return "\(model.projectsFolderDisplay) · \(count == 1 ? "1 project" : "\(count) projects") found"
    }
}

@MainActor
struct MainView: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
        } detail: {
            DetailContainer()
        }
        .navigationTitle(AppInfo.name)
        .navigationSubtitle(model.projectsFolderDisplay)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let update = model.availableUpdate {
                    Button {
                        model.showingUpdate = true
                    } label: {
                        Label("Update to \(update.version)", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("A new version of \(AppInfo.name) is available")
                }
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    Button("Choose another folder…") { model.chooseProjectsFolder() }
                    Button("Show in Finder") { model.revealProjectsFolder() }
                } label: {
                    Label("Projects folder", systemImage: "folder")
                }
                .help("Projects folder: \(model.projectsFolderDisplay)")
                .disabled(model.isBusy)
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
                .keyboardShortcut("r")
                .disabled(model.isBusy)
                Button {
                    model.showingActivity = true
                } label: {
                    Label("Activity", systemImage: "list.bullet.rectangle")
                }
                .help("Details of what the app did")
            }
        }
    }
}

@MainActor
struct SidebarView: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $model.filter) {
                ForEach(ProjectFilter.allCases) { option in
                    Text("\(option.title) \(model.count(in: option))").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if model.visibleProjects.isEmpty {
                SidebarEmptyState()
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleProjects) { project in
                        ProjectRow(project: project)
                            .tag(project.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search projects")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .onChange(of: model.filter) { _ in model.pruneSelection() }
        .onChange(of: model.searchText) { _ in model.pruneSelection() }
    }
}

@MainActor
struct SidebarFooter: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        let pending = model.needsSetupProjects
        if !pending.isEmpty {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.setUp(pending)
                } label: {
                    Label(model.setUpTitle(for: pending), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!model.canRun)
                .padding(10)
            }
            .background(.bar)
        }
    }
}

@MainActor
struct SidebarEmptyState: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(iconColor)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.projects.isEmpty {
                Button("Choose folder…") { model.chooseProjectsFolder() }
                    .buttonStyle(.borderedProminent)
            } else if model.searchText.isEmpty && model.filter != .all {
                Button("Show all projects") { model.filter = .all }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        if model.projects.isEmpty { return "folder.badge.questionmark" }
        if !model.searchText.isEmpty { return "magnifyingglass" }
        return model.filter == .needsSetup ? "checkmark.seal.fill" : "tray"
    }

    private var iconColor: Color {
        model.filter == .needsSetup && !model.projects.isEmpty && model.searchText.isEmpty ? .green : .secondary
    }

    private var title: String {
        if model.projects.isEmpty { return "No projects in \(model.projectsFolderDisplay)" }
        if !model.searchText.isEmpty { return "No matches" }
        return model.filter == .needsSetup ? "Everything is set up" : "Nothing is set up yet"
    }

    private var message: String {
        if model.projects.isEmpty {
            return "A project is a folder with package.json, go.mod, composer.json or pyproject.toml."
        }
        if !model.searchText.isEmpty { return "No project name contains “\(model.searchText)”." }
        return model.filter == .needsSetup
            ? "All projects have the latest rules."
            : "Set up a project from “Needs setup”."
    }
}

@MainActor
struct ProjectRow: View {
    @EnvironmentObject private var model: StarterModel
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(project.stacks.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            StatusPill(status: model.displayStatus(of: project))
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(project.isInstalled ? "Update" : "Set up") { model.setUp([project]) }
                .disabled(!model.canRun)
            Button("Show in Finder") { model.reveal(project) }
            if project.isInstalled {
                Divider()
                Button("Repair…") { model.repair([project]) }
                    .disabled(!model.canRun)
                Button("Remove…") { model.remove([project]) }
                    .disabled(!model.canRun)
            }
        }
    }
}

@MainActor
struct StatusPill: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .working {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.icon)
            }
            Text(status.title)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
        .foregroundStyle(status.color)
    }
}

@MainActor
struct StackTag: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

@MainActor
struct DetailContainer: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.notice {
                NoticeBar(notice: notice)
                    .padding(18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
    }

    @ViewBuilder
    private var content: some View {
        let selected = model.selectedProjects
        if selected.count == 1, let project = selected.first {
            ProjectDetailView(projectID: project.id)
        } else if selected.count > 1 {
            BulkDetailView(projects: selected)
        } else {
            OverviewView()
        }
    }
}

@MainActor
struct OverviewView: View {
    @EnvironmentObject private var model: StarterModel

    var body: some View {
        VStack(spacing: 16) {
            AppIconView(size: 80)
            Text("Select a project")
                .font(.title2.weight(.semibold))
            Text("Pick a project on the left to set it up or change its settings.\nHold ⌘ or ⇧ to select several.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                OverviewStat(value: model.count(status: .notSetUp), label: "Not set up", color: .secondary)
                OverviewStat(value: model.count(status: .updateAvailable), label: "Update available", color: .orange)
                OverviewStat(value: model.count(status: .ready), label: "Ready", color: .green)
            }
            .padding(.top, 6)
            if !model.gitAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Git isn’t installed, so design skills can’t be downloaded.")
                    Button("Install Git") { model.installCommandLineTools() }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8)
            }
        }
        .padding(32)
    }
}

@MainActor
struct OverviewStat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title.weight(.semibold))
                .foregroundStyle(value == 0 ? Color.secondary : color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

@MainActor
struct ProjectDetailView: View {
    @EnvironmentObject private var model: StarterModel
    let projectID: String

    var body: some View {
        if let project = model.project(withID: projectID) {
            Form {
                Section {
                    ProjectHeader(project: project)
                }
                Section {
                    PrimaryActionView(project: project)
                }
                if project.isInstalled {
                    claudeSection(project)
                    designSection(project)
                    SkillSections(project: project)
                    maintenanceSection(project)
                } else {
                    claudeSection(project)
                }
            }
            .formStyle(.grouped)
        } else {
            OverviewView()
        }
    }

    private func claudeSection(_ project: Project) -> some View {
        Section {
            Picker("Claude replies in", selection: Binding(
                get: { model.language(for: project) },
                set: { model.setLanguage($0, for: [project]) }
            )) {
                ForEach(StarterModel.languages, id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Explanations, questions and reports. Code, commits and pull requests stay in English.")
        }
    }

    private func designSection(_ project: Project) -> some View {
        Section {
            Toggle("Protect the current design", isOn: Binding(
                get: { project.isDesignLocked },
                set: { model.setDesignLocked($0, for: [project]) }
            ))
            Picker("Project type", selection: Binding(
                get: { project.phase == "new" ? "new" : "existing" },
                set: { model.setPhase($0, for: [project]) }
            )) {
                Text("Existing").tag("existing")
                Text("New").tag("new")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Design")
        } footer: {
            Text(designFooter(project))
        }
    }

    private func designFooter(_ project: Project) -> String {
        var parts = [project.isDesignLocked
            ? "Claude won’t change colors, fonts, spacing or layout unless you ask."
            : "Claude may change the design."]
        if project.phase == "new" {
            parts.append(project.kickoffDone
                ? "New project: the plan agreed with Claude is in .claude/KICKOFF.md."
                : "New project: Claude plans the product and design with you before writing code. Open the project in Claude Code to start.")
        } else {
            parts.append("Existing project: Claude follows what’s already there.")
        }
        return parts.joined(separator: " ")
    }

    private func maintenanceSection(_ project: Project) -> some View {
        Section {
            MaintenanceRow(
                title: "Repair",
                detail: "Set everything up again from scratch if something seems broken.",
                buttonTitle: "Repair…",
                isDestructive: false
            ) {
                model.repair([project])
            }
            MaintenanceRow(
                title: "Remove from this project",
                detail: "Removes rules, hooks and skills. Your code isn’t touched.",
                buttonTitle: "Remove…",
                isDestructive: true
            ) {
                model.remove([project])
            }
        } header: {
            Text("Maintenance")
        }
    }
}

@MainActor
struct ProjectHeader: View {
    @EnvironmentObject private var model: StarterModel
    let project: Project

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(project.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    StatusPill(status: model.displayStatus(of: project))
                    ForEach(project.stacks, id: \.self) { StackTag(label: $0) }
                }
            }
            Spacer()
            Button("Show in Finder") { model.reveal(project) }
                .buttonStyle(.link)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
struct PrimaryActionView: View {
    @EnvironmentObject private var model: StarterModel
    let project: Project

    var body: some View {
        switch model.displayStatus(of: project) {
        case .working:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Working on it…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        case .notSetUp:
            actionRow(
                text: "Adds Claude’s rules, agents and safety checks to this project. Your code isn’t changed.",
                button: "Set up project"
            )
        case .updateAvailable:
            actionRow(
                text: "Newer rules are available (\(project.installedVersion ?? "?") → \(model.starterVersion ?? "?")). Your settings are kept.",
                button: "Update"
            )
        case .ready:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready")
                        .font(.headline)
                    Text("Claude Code follows these rules whenever you work in this project.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Label("The last action didn’t finish.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                HStack {
                    Button("Show details") { model.showingActivity = true }
                    Button("Try again") { model.setUp([project]) }
                        .disabled(!model.canRun)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func actionRow(text: String, button: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                model.setUp([project])
            } label: {
                Text(button)
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canRun)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
struct SkillSections: View {
    @EnvironmentObject private var model: StarterModel
    @State private var showingBuiltin = false
    @State private var showingAddSkill = false
    let project: Project

    var body: some View {
        let recommended = model.recommendedItems(for: project)
        let missing = recommended.filter { !project.catalogInstalled.contains($0.id) }

        Section {
            DisclosureGroup(isExpanded: $showingBuiltin) {
                ForEach(model.builtinSkills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(skill.id)")
                            .font(.body.monospaced())
                        Text(skill.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            } label: {
                Label("\(model.builtinSkills.count) built-in skills, always on", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Built-in skills come with \(AppInfo.name): planning, agents, tests, security, reviews. Claude uses them on its own, or type one in Claude Code, e.g. /kickoff.")
        }

        if !recommended.isEmpty {
            Section {
                ForEach(recommended) { item in
                    SkillToggleRow(item: item, project: project)
                }
                if !missing.isEmpty {
                    HStack {
                        Text(missing.count == 1 ? "1 recommended item is off" : "\(missing.count) recommended items are off")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Turn on recommended") { model.turnOnRecommended(for: project) }
                            .disabled(!model.canRun)
                    }
                }
            } header: {
                Text("Recommended for this project")
            } footer: {
                Text("Chosen from the project’s stack and switched on when a project is set up. Tools need a one-time approval the next time Claude Code starts.")
            }
        }

        ForEach(model.catalogCategories.filter { $0 != CatalogItem.mySkills }, id: \.self) { category in
            let items = model.otherItems(in: category, for: project)
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        SkillToggleRow(item: item, project: project)
                    }
                } header: {
                    Text(StarterModel.categoryTitle(category))
                } footer: {
                    if category == "UI/UX" {
                        Text(designSkillsFooter)
                    } else if category == "MCP" {
                        Text("Claude Code asks you to approve tools the next time it starts in this project.")
                    }
                }
            }
        }

        Section {
            ForEach(model.mySkills) { item in
                SkillToggleRow(item: item, project: project)
            }
            Button {
                showingAddSkill = true
            } label: {
                Label("Add your own skill…", systemImage: "plus.circle")
            }
            .disabled(!model.canRun)
            .sheet(isPresented: $showingAddSkill) {
                AddSkillSheet()
                    .environmentObject(model)
            }
        } header: {
            Text("My skills")
        } footer: {
            Text(model.mySkills.isEmpty
                 ? "Add any skill from GitHub or from a folder on this Mac. It then shows up here in every project."
                 : "Your own skills, available in every project. Right-click one to remove it from the list.")
        }
    }

    private var designSkillsFooter: String {
        if project.phase == "new" {
            return "New project: during the kickoff conversation Claude suggests one design skill that fits and turns it on. Switch one on yourself if you already know the style. Use one at a time — several give Claude conflicting directions."
        }
        return "The design is \(project.isDesignLocked ? "protected" : "open"), so these only matter when you ask Claude for design work. Use one at a time — several give Claude conflicting directions."
    }
}

@MainActor
struct SkillToggleRow: View {
    @EnvironmentObject private var model: StarterModel
    let item: CatalogItem
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                    if item.type == "mcp" {
                        Text("Tool")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            ZStack {
                if model.isPending(item, for: project) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 18)
            Toggle("", isOn: Binding(
                get: { project.catalogInstalled.contains(item.id) },
                set: { model.setCatalogItem(item, enabled: $0, for: [project]) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!model.canRun)
        }
        .contextMenu {
            if item.isMine {
                Button("Remove from my skills…") { model.unregisterSkill(item) }
            }
        }
    }
}

@MainActor
struct AddSkillSheet: View {
    @EnvironmentObject private var model: StarterModel
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var choices: [SkillChoice] = []
    @State private var picked: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your own skill")
                .font(.title2.weight(.semibold))
            Text("A skill is a folder with a SKILL.md file. Paste a GitHub link (a repository or a skill folder in it) or choose a folder on this Mac. It’s added to “My skills”, then you switch it on per project.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("github.com/owner/repo or a folder path", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                    .onChange(of: source) { _ in
                        choices = []
                        picked = nil
                        errorMessage = nil
                    }
                Button("Choose folder…") { chooseFolder() }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !choices.isEmpty {
                Text("This source has \(choices.count) skills. Pick the one you want:")
                    .font(.headline)
                List(choices, selection: $picked) { choice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.name)
                        Text(choice.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(choice.name)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 220)
            }
            Spacer(minLength: 0)
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the skill…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(choices.isEmpty ? "Add" : "Add selected") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || source.trimmingCharacters(in: .whitespaces).isEmpty || (!choices.isEmpty && picked == nil))
            }
        }
        .padding(22)
        .frame(width: 620, height: choices.isEmpty ? 280 : 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a skill folder (with SKILL.md) or a folder that contains skills"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url.path
    }

    private func submit() {
        guard !isWorking, !source.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !choices.isEmpty && picked == nil { return }
        isWorking = true
        errorMessage = nil
        let pick = choices.isEmpty ? nil : picked
        Task {
            let outcome = await model.registerSkill(source: source, pick: pick)
            isWorking = false
            switch outcome {
            case .added:
                dismiss()
            case .choices(let list):
                choices = list
                picked = list.first?.name
            case .failed(let message):
                errorMessage = message
            }
        }
    }
}

@MainActor
struct MaintenanceRow: View {
    let title: String
    let detail: String
    let buttonTitle: String
    let isDestructive: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDestructive {
                Button(buttonTitle, role: .destructive, action: action)
                    .foregroundStyle(.red)
            } else {
                Button(buttonTitle, action: action)
            }
        }
    }
}

@MainActor
struct BulkDetailView: View {
    @EnvironmentObject private var model: StarterModel
    let projects: [Project]

    var body: some View {
        let pending = projects.filter { model.status(of: $0) != .ready }
        let installed = projects.filter(\.isInstalled)
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(projects.count) projects selected")
                            .font(.title2.weight(.semibold))
                        Text(projects.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if pending.isEmpty {
                    Label("All selected projects are ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        Text("Set up or update everything selected in one go.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(model.setUpTitle(for: pending)) { model.setUp(pending) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.canRun)
                    }
                }
            }
            if !installed.isEmpty {
                Section {
                    Picker("Claude replies in", selection: Binding(
                        get: { commonLanguage(installed) },
                        set: { model.setLanguage($0, for: installed) }
                    )) {
                        if commonLanguage(installed).isEmpty {
                            Text("Mixed").tag("")
                        }
                        ForEach(StarterModel.languages, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Text("Design")
                        Spacer()
                        Button("Protect current design") { model.setDesignLocked(true, for: installed) }
                        Button("Allow design changes") { model.setDesignLocked(false, for: installed) }
                    }
                } header: {
                    Text("Settings for \(installed.count) set-up \(installed.count == 1 ? "project" : "projects")")
                }
                .disabled(!model.canRun)
                ForEach(model.catalogCategories, id: \.self) { category in
                    Section {
                        ForEach(model.catalogItems(in: category)) { item in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text("In \(installed.filter { $0.catalogInstalled.contains(item.id) }.count) of \(installed.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") { model.setCatalogItem(item, enabled: true, for: installed) }
                                Button("Remove") { model.setCatalogItem(item, enabled: false, for: installed) }
                            }
                        }
                    } header: {
                        Text(StarterModel.categoryTitle(category))
                    }
                    .disabled(!model.canRun)
                }
                Section {
                    MaintenanceRow(
                        title: "Repair \(installed.count)",
                        detail: "Set everything up again from scratch.",
                        buttonTitle: "Repair…",
                        isDestructive: false
                    ) {
                        model.repair(installed)
                    }
                    MaintenanceRow(
                        title: "Remove from \(installed.count)",
                        detail: "Removes rules, hooks and skills. Code isn’t touched.",
                        buttonTitle: "Remove…",
                        isDestructive: true
                    ) {
                        model.remove(installed)
                    }
                } header: {
                    Text("Maintenance")
                }
                .disabled(!model.canRun)
            }
        }
        .formStyle(.grouped)
    }

    private func commonLanguage(_ targets: [Project]) -> String {
        let languages = Set(targets.map { model.language(for: $0) })
        return languages.count == 1 ? languages.first ?? "" : ""
    }
}

@MainActor
struct NoticeBar: View {
    @EnvironmentObject private var model: StarterModel
    let notice: Notice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.red : Color.green)
            Text(notice.text)
                .lineLimit(2)
            if notice.isError {
                Button("Show details") { model.showingActivity = true }
            }
            Button {
                model.dismissNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

@MainActor
struct ActivityView: View {
    @EnvironmentObject private var model: StarterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log, forType: .string)
                }
                .disabled(model.log.isEmpty)
                Button("Clear") { model.clearLog() }
                    .disabled(model.log.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(model.log.isEmpty ? "Nothing has happened yet." : model.log)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(model.log.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        }
        .padding(20)
        .frame(width: 720, height: 480)
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: StarterModel
    @State private var showingAddSkill = false
    @State private var token = ""
    @State private var hasToken = GitHubToken.stored() != nil

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.projectsFolderDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { model.chooseProjectsFolder() }
                    }
                }
            } header: {
                Text("Projects")
            }
            Section {
                Picker("Claude replies in", selection: $model.defaultLanguage) {
                    ForEach(StarterModel.languages, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("New projects")
            } footer: {
                Text("Used when a project is set up. Each project can be changed later in its own settings.")
            }
            Section {
                if model.mySkills.isEmpty {
                    Text("None yet. Add a skill from GitHub or a folder on this Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.mySkills) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.path ?? item.repo ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove…") { model.unregisterSkill(item) }
                    }
                }
                Button("Add your own skill…") { showingAddSkill = true }
                    .disabled(!model.canRun)
            } header: {
                Text("My skills")
            }
            Section {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Source", value: Updater.repository.map { "github.com/\($0)" } ?? "Not set up in this build")
                HStack {
                    Text(model.updateStatus ?? "Checks automatically when the app opens.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.availableUpdate != nil {
                        Button("Update…") { model.showingUpdate = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Check now") { Task { await model.checkForUpdates(userInitiated: true) } }
                        .disabled(Updater.repository == nil)
                }
                if hasToken {
                    HStack {
                        Label("GitHub token saved in Keychain", systemImage: "key.fill")
                        Spacer()
                        Button("Remove") {
                            GitHubToken.save("")
                            hasToken = false
                        }
                    }
                } else {
                    HStack {
                        SecureField("GitHub token (only for a private repository)", text: $token)
                        Button("Save") {
                            GitHubToken.save(token)
                            token = ""
                            hasToken = GitHubToken.stored() != nil
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("A token is needed only when the GitHub repository is private: a fine-grained token with read access to its contents. If GitHub CLI (gh) is signed in on this Mac, its login is used automatically.")
            }
            Section {
                LabeledContent("Rules", value: model.starterVersion ?? "Not found")
                LabeledContent("Node.js", value: model.nodePath ?? "Not found")
                LabeledContent("Git", value: model.gitAvailable ? "Installed" : "Not found")
                Button("Show activity…") { model.showingActivity = true }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .sheet(isPresented: $showingAddSkill) {
            AddSkillSheet()
                .environmentObject(model)
        }
    }
}

@MainActor
struct UpdateSheet: View {
    @EnvironmentObject private var model: StarterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let release = model.availableUpdate {
                HStack(spacing: 14) {
                    AppIconView(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A new version is available")
                            .font(.title2.weight(.semibold))
                        Text("\(AppInfo.name) \(release.version) — you have \(AppInfo.version).")
                            .foregroundStyle(.secondary)
                    }
                }
                if !release.notes.isEmpty {
                    Text("What’s new")
                        .font(.headline)
                    ScrollView {
                        Text(release.notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                }
                Text("The app downloads the update and restarts. Your projects and settings stay as they are; projects that need the new rules then show “Update available”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Release page") { model.openReleasePage() }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isUpdating)
                    Button {
                        Task { await model.installUpdate() }
                    } label: {
                        if model.isUpdating {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(model.updatePhase.isEmpty ? "Updating…" : model.updatePhase)
                            }
                        } else {
                            Text("Update and restart")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isUpdating)
                }
            } else {
                Text("You’re up to date.")
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
