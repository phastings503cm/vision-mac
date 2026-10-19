import Foundation

// MARK: - Who the app is
//
// Every name the app is known by on this Mac — its bundle identifier, its data folder, its Keychain items, the
// folders it reads in a project, how it introduces itself to servers — comes from here, so nothing else spells
// one out. The names the app had before it was called Vision live in `AppIdentity.Legacy`: only the code that
// brings an existing user's data over (and the readers of users' own repos) uses them.

public enum AppIdentity {
    /// The product's name, as the user sees it.
    public static let name = "Vision"

    /// The bundle identifier `bundle.sh` gives the app. The settings file (UserDefaults) is named after it.
    public static let bundleIdentifier = "com.503cm.vision.mac"

    /// The app's folder under `~/Library/Application Support`.
    public static let supportFolderName = "Vision"

    /// The folder in a project that holds the app's own skills, agents and plugins.
    public static let projectFolderName = ".vision"

    /// The project instruction file named after the app.
    public static let projectInstructionsFileName = "VISION.md"

    /// `TERM_PROGRAM` in the integrated terminal, for shell configs that branch on it.
    public static let terminalProgram = "Vision"

    /// The AWS CLI profile the Amazon Bedrock setup signs in with when it makes one of its own. Routes made
    /// earlier keep the profile they name (it is stored on the route).
    public static let awsProfile = "vision-bedrock"

    /// Keychain services (generic passwords) the app keeps secrets under.
    public enum KeychainService {
        /// API keys, one item per route (account = route id).
        public static let provider = "Vision.provider"
        /// The sensitive-data shield's custom terms (account "terms").
        public static let shield = "Vision.shield"
        /// Spark Swapper app tokens and passwords (account = connection id).
        public static let sparkSwapper = "Vision.sparkSwapper"
        /// The credential vault: every value in one item (account "secrets").
        public static let vault = "Vision.vault"
        /// The Guardian sign-in: session token, email, deployment address
        /// (accounts "token", "email", "address").
        public static let guardian = "Vision.guardian"
    }

    /// The app's version from its bundle ("0.15.0"); "dev" in a test run or an unbundled build.
    public static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (short?.isEmpty == false && Bundle.main.bundlePath.hasSuffix(".app")) ? short! : "dev"
    }

    /// How the app names itself to the servers it calls: "Vision/0.15.0 (macOS)". Some plans (Kimi Code) check
    /// which app is calling: the app says honestly what it is, and never borrows another tool's identity.
    public static var userAgent: String { "Vision/\(version) (macOS)" }

    /// The Amazon Bedrock client's user agent: "Vision-Mac/0.15.0".
    public static var bedrockUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Vision-Mac/\(version ?? "dev")"
    }

    /// The names this app had before it was renamed Vision (it was called DSH). They are read, never written:
    /// to bring an existing user's settings, data and Keychain items over once, and to keep reading the folders and
    /// files already committed in users' projects. Do not rename these — they name what is on users' Macs.
    public enum Legacy {
        /// The app's name before the rename (shown in the one-time "now called Vision" notice).
        public static let name = "DSH"
        /// The bundle identifier, and so the settings file, before the rename.
        public static let bundleIdentifier = "dev.local.dsh.mac"
        /// The data folder under `~/Library/Application Support` before the rename.
        public static let supportFolderName = "DSHMac"
        /// The project folder before the rename. Users' repos may have it committed: it is read forever, next to
        /// `.vision`, and never written or moved.
        public static let projectFolderName = ".dsh"
        /// The project instruction file before the rename; read forever, never written.
        public static let projectInstructionsFileName = "DSH.md"
        /// The AWS CLI profile the Bedrock setup made before the rename. Routes that name it keep it.
        public static let awsProfile = "dsh-bedrock"
        /// Keychain services before the rename, by the service that replaces each.
        public static let keychainServices: [String: String] = [
            KeychainService.provider: "DSHMac.provider",
            KeychainService.shield: "DSHMac.shield",
            KeychainService.sparkSwapper: "DSHMac.sparkSwapper",
            KeychainService.vault: "DSHMac.vault",
        ]
    }
}

// MARK: - Where the app keeps things

public enum AppPaths {
    /// `~/Library/Application Support` (a stand-in for it in an isolated run, see `IsolatedRun`).
    public static var applicationSupport: URL {
        IsolatedRun.applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// The app's data folder: `~/Library/Application Support/Vision`. Chats, the task queue, user skills, plugins,
    /// the vault's index and each plain chat's scratch folder live under it.
    ///
    /// Settled once per run (after the launch migration): while the data an earlier build kept in the legacy folder
    /// hasn't been brought over — the migration hasn't run yet, or couldn't finish — the app keeps working in the
    /// legacy folder, so it never starts empty next to the user's real data.
    public static let support: URL = resolveSupport(in: applicationSupport)

    /// The data folder to use, given `~/Library/Application Support` (see `support`).
    public static func resolveSupport(in base: URL, fileManager: FileManager = .default) -> URL {
        let current = base.appendingPathComponent(AppIdentity.supportFolderName, isDirectory: true)
        let legacy = base.appendingPathComponent(AppIdentity.Legacy.supportFolderName, isDirectory: true)
        if DataFolderMigration.isSettled(current, fileManager: fileManager) { return current }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue { return legacy }
        return current
    }

    /// One JSON file per chat.
    public static var conversations: URL { support.appendingPathComponent("conversations", isDirectory: true) }
    /// The task queue.
    public static var taskQueueFile: URL { support.appendingPathComponent("task-queue.json") }
    /// What model servers refused, per server and model (see `RequestAdaptationStore`).
    public static var requestAdaptationsFile: URL { support.appendingPathComponent("request-adaptations.json") }
    /// The user's own plugin manifests.
    public static var plugins: URL { support.appendingPathComponent("plugins", isDirectory: true) }

    /// `<project>/.vision/<sub>`: where the app writes into a project.
    public static func projectFolder(_ project: URL, _ sub: String) -> URL {
        project.appendingPathComponent(AppIdentity.projectFolderName, isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }

    /// `<project>/.dsh/<sub>`: the same folder as an earlier build named it. Read, never written.
    public static func legacyProjectFolder(_ project: URL, _ sub: String) -> URL {
        project.appendingPathComponent(AppIdentity.Legacy.projectFolderName, isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }

    /// Every folder the app reads `<sub>` from in a project, the one it writes first.
    public static func projectFolders(_ project: URL, _ sub: String) -> [URL] {
        [projectFolder(project, sub), legacyProjectFolder(project, sub)]
    }
}
