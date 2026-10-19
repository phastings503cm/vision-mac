import Foundation
import CryptoKit

// MARK: - Bringing OpenClaw in, and sending Vision's things back
//
// Import — the person ticks what to bring; this applies exactly that:
//   skills        → copied into Vision's own skills through the same importer Settings ▸ Skills uses (its naming,
//                   validation and conflict rules); credential files and files with a key inside are left out
//   memory        → the Mac's memory is files: MEMORY.md and USER.md go into ~/MEMORY.md, daily logs into
//                   ~/memory/<day>.md, personality and rules (opt-in) into ~/VISION.md — each as a marked block, so
//                   importing again replaces the block instead of duplicating it
//   credentials   → the Credentials Vault, "ask first" unless chosen otherwise; values are moved, never logged
//   model servers → handed back to the app, which adds them as routes
//
// Export — Vision's skills into OpenClaw's managed skills folder, Vision's memory into the workspace's MEMORY.md and
// memory/ as marked blocks, and vault secrets into OpenClaw's .env — that last only after an explicit confirmation.

public enum OpenClawConflict: String, Sendable, CaseIterable, Codable {
    /// Keep both: the incoming one gets a new name.
    case keepBoth
    /// The incoming one replaces what is there.
    case replace
    /// Leave what is there alone.
    case skip

    public var label: String {
        switch self {
        case .keepBoth: "Keep both (rename the new one)"
        case .replace: "Replace what is there"
        case .skip: "Skip it"
        }
    }
}

/// What the person ticked.
public struct OpenClawSelection: Sendable, Equatable {
    /// Skills to bring, by directory path.
    public var skills: Set<String> = []
    /// Memory files to bring, by path.
    public var noteFiles: Set<String> = []
    /// Credentials to bring, by name, with what the agent may do with each.
    public var credentials: [String: VaultEntry.AgentAccess] = [:]
    /// Model servers to bring, by id.
    public var modelServers: Set<String> = []
    /// Hold the skills for approval in Settings ▸ Skills instead of switching them on.
    public var skillsAsDrafts = false
    public var skillConflict: OpenClawConflict = .keepBoth
    public var credentialConflict: OpenClawConflict = .keepBoth

    public init() {}

    /// What is ticked when the sheet opens: memory, recent daily logs and USER.md; skills not hidden by another of
    /// the same name (plugin skills need OpenClaw's plugins, so they are opt-in); credentials as "ask first";
    /// model servers Vision can talk to.
    public static func suggested(_ bundle: OpenClawBundle) -> OpenClawSelection {
        var selection = OpenClawSelection()
        selection.skills = Set(bundle.skills.filter { !$0.shadowed && $0.location != "plugin" }.map(\.directory.path))
        selection.noteFiles = Set(bundle.noteFiles.filter(\.selectedByDefault).map(\.path.path))
        selection.credentials = Dictionary(uniqueKeysWithValues: bundle.credentials.map { ($0.name, VaultEntry.AgentAccess.ask) })
        selection.modelServers = Set(bundle.modelServers.filter(\.compatible).map(\.id))
        return selection
    }
}

public struct OpenClawImportResult: Sendable, Equatable {
    public var skills: [String] = []
    public var skillDrafts: [String] = []
    /// Skill name → why it wasn't brought.
    public var skillsSkipped: [String: String] = [:]
    public var notesAdded = 0
    public var notesUpdated = 0
    public var notesUnchanged = 0
    /// The vault names created or replaced (never the values).
    public var credentials: [String] = []
    public var credentialsSkipped: [String: String] = [:]
    /// The model servers to add as routes — the app does that.
    public var modelServers: [OpenClawModelServer] = []
    public var problems: [String] = []

    /// "3 skills, 41 memory files, 6 keys and passwords and 1 model server".
    public var summary: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        var parts: [String] = []
        if skills.count + skillDrafts.count > 0 { parts.append(n(skills.count + skillDrafts.count, "skill", "skills")) }
        if notesAdded + notesUpdated > 0 { parts.append(n(notesAdded + notesUpdated, "memory file", "memory files")) }
        if !credentials.isEmpty { parts.append(n(credentials.count, "key or password", "keys and passwords")) }
        if !modelServers.isEmpty { parts.append(n(modelServers.count, "model server", "model servers")) }
        switch parts.count {
        case 0: return "nothing new"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

// MARK: - Marked blocks in Markdown files

/// A block of text in a Markdown file that one importer owns, between an HTML-comment begin and end marker that
/// carry the block's name and a fingerprint of its contents. Upserting the same block again is a no-op when the
/// contents are the same, and replaces the block in place when they changed.
public enum MarkdownBlocks {
    public enum Outcome: Sendable, Equatable { case added, updated, unchanged }

    public static func begin(_ tag: String, _ name: String, hash: String) -> String { "<!-- \(tag):begin \(name) \(hash) -->" }
    public static func end(_ tag: String, _ name: String) -> String { "<!-- \(tag):end \(name) -->" }

    public static func upsert(tag: String, name: String, title: String, body: String, into text: String) -> (String, Outcome) {
        let hash = CredentialVault.fingerprint(body)
        let block = begin(tag, name, hash: hash) + "\n## " + title + "\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n" + end(tag, name)
        let beginPrefix = "<!-- \(tag):begin \(name) "
        if let start = text.range(of: beginPrefix) {
            let lineEnd = text[start.lowerBound...].range(of: "-->")?.upperBound ?? start.upperBound
            if text[start.lowerBound..<lineEnd].contains(hash) { return (text, .unchanged) }
            if let close = text.range(of: end(tag, name), range: lineEnd..<text.endIndex) {
                var out = text
                out.replaceSubrange(start.lowerBound..<close.upperBound, with: block)
                return (out, .updated)
            }
        }
        var out = text
        if !out.isEmpty {
            while out.hasSuffix("\n\n\n") { out.removeLast() }
            out += out.hasSuffix("\n") ? "\n" : "\n\n"
        }
        return (out + block + "\n", .added)
    }

    /// Write `text` to a file atomically, creating its folder.
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Import

public enum OpenClawImporter {
    static let maxFilesPerSkill = 300
    static let maxBytesPerSkill = 5_000_000
    static let maxBytesPerFile = 1_500_000
    public static let blockTag = "openclaw-import"

    /// Apply the selection. A nil `vault` / `locations` / `home` skips that kind.
    public static func apply(_ bundle: OpenClawBundle, selection: OpenClawSelection, vault: CredentialVault?,
                             locations: SkillLocations?, home: URL?) -> OpenClawImportResult {
        var result = OpenClawImportResult()

        if let home {
            for file in bundle.noteFiles where selection.noteFiles.contains(file.path.path) {
                if secretDetector.matches(in: file.text).isEmpty == false {
                    result.problems.append("\(file.name) was left out because it holds what looks like a key or a password. Those belong in the vault.")
                    continue
                }
                let (target, title) = memoryTarget(file, home: home)
                do {
                    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                    let (text, outcome) = MarkdownBlocks.upsert(tag: blockTag, name: file.name, title: title, body: file.text, into: existing)
                    switch outcome {
                    case .added: result.notesAdded += 1
                    case .updated: result.notesUpdated += 1
                    case .unchanged: result.notesUnchanged += 1
                    }
                    if outcome != .unchanged { try MarkdownBlocks.write(text, to: target) }
                } catch {
                    result.problems.append("\(file.name) couldn't be saved: \(error.localizedDescription)")
                }
            }
        }

        if let vault {
            for credential in bundle.credentials {
                guard let access = selection.credentials[credential.name] else { continue }
                switch addToVault(vault, credential, access: access, conflict: selection.credentialConflict) {
                case .success(let name): result.credentials.append(name)
                case .failure(let reason): result.credentialsSkipped[credential.name] = reason.message
                }
            }
        }

        if let locations {
            let chosen = bundle.skills.filter { selection.skills.contains($0.directory.path) }
            importSkills(chosen, locations: locations, asDrafts: selection.skillsAsDrafts, conflict: selection.skillConflict, into: &result)
        }

        result.modelServers = bundle.modelServers.filter { selection.modelServers.contains($0.id) }
        return result
    }

    /// Where a memory file goes in the Mac's file memory, and the heading its block gets.
    static func memoryTarget(_ file: OpenClawNoteFile, home: URL) -> (URL, String) {
        switch file.kind {
        case .memory: (home.appendingPathComponent("MEMORY.md"), "From OpenClaw — \(file.name)")
        case .about: (home.appendingPathComponent("MEMORY.md"), "About me — from OpenClaw \(file.name)")
        case .daily:
            (home.appendingPathComponent("memory/\(file.day ?? "openclaw-" + (file.path.deletingPathExtension().lastPathComponent)).md"),
             "From OpenClaw — \(file.name)")
        case .persona: (home.appendingPathComponent(AppIdentity.projectInstructionsFileName), "Personality — from OpenClaw \(file.name)")
        case .instructions: (home.appendingPathComponent(AppIdentity.projectInstructionsFileName), "Rules — from OpenClaw \(file.name)")
        }
    }

    /// Keys and passwords only (no emails, phone numbers or names): what must never ride along in a skill or a note.
    static let secretDetector: SensitiveDetector = {
        var settings = ShieldSettings()
        settings.emails = false
        settings.phones = false
        settings.ids = false
        settings.ips = false
        settings.terms = false
        settings.customTerms = []
        return SensitiveDetector(settings: settings)
    }()

    struct Refusal: Error { var message: String }

    /// Add one credential; the name it landed under, or why it didn't.
    static func addToVault(_ vault: CredentialVault, _ credential: OpenClawCredential, access: VaultEntry.AgentAccess,
                           conflict: OpenClawConflict) -> Result<String, Refusal> {
        let value = credential.secret.reveal()
        let fingerprint = credential.secret.fingerprint
        var tags = ["openclaw"]
        if let provider = credential.provider, !provider.isEmpty { tags.append(provider) }
        let description = credential.description + (credential.alsoNamed.isEmpty ? "" : " Also known as \(credential.alsoNamed.joined(separator: ", ")).")
        var name = credential.name
        for attempt in 1...6 {
            if let existing = vault.entry(named: name) {
                if existing.fingerprint == fingerprint { return .failure(Refusal(message: "\(name) is already in the vault with this value.")) }
                switch conflict {
                case .skip:
                    return .failure(Refusal(message: "\(name) is already in the vault with a different value; kept that one."))
                case .replace:
                    var updated = existing
                    updated.kind = credential.kind
                    if updated.description.isEmpty { updated.description = description }
                    do {
                        try vault.update(updated, value: value)
                        return .success(name)
                    } catch {
                        return .failure(Refusal(message: error.localizedDescription))
                    }
                case .keepBoth:
                    name = renamed(credential.name, attempt + 1)
                    continue
                }
            }
            do {
                try vault.add(name: name, value: value, kind: credential.kind, description: description, tags: tags,
                              username: credential.username, url: credential.url, access: access)
                return .success(name)
            } catch {
                return .failure(Refusal(message: error.localizedDescription))
            }
        }
        return .failure(Refusal(message: "Its name was taken six times over."))
    }

    static func renamed(_ base: String, _ n: Int) -> String {
        let suffix = n == 2 ? "_OPENCLAW" : "_OPENCLAW_\(n)"
        let head = base.count + suffix.count > OpenClawReader.maxNameLength ? String(base.prefix(OpenClawReader.maxNameLength - suffix.count)) : base
        return head + suffix
    }

    /// Files that are credentials whatever they are called inside a skill: never copied.
    public static func isCredentialFile(_ relativePath: String) -> Bool {
        let name = (relativePath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
        if [".env", ".netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
            "token", "secrets", "auth.json", "service-account.json"].contains(name) { return true }
        if name.hasPrefix(".env."), ![".env.example", ".env.sample", ".env.template"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return ["pem", "key", "p12", "pfx", "jks", "keystore", "kdbx", "ppk"].contains(ext)
            || name.hasPrefix("credentials.") || name.hasPrefix("secrets.")
    }

    /// A relative path of ordinary segments: no "..", nothing absolute.
    static func isSafeRelative(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !segments.isEmpty, !path.hasPrefix("/") else { return false }
        return !segments.contains { $0 == "." || $0 == ".." || $0.contains("\0") }
    }

    static func importSkills(_ chosen: [OpenClawSkill], locations: SkillLocations, asDrafts: Bool, conflict: OpenClawConflict,
                             into result: inout OpenClawImportResult) {
        guard !chosen.isEmpty else { return }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("vision-openclaw-\(UUID().uuidString.prefix(12))", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        var staged: [String: OpenClawSkill] = [:]
        var hashes: [String: String] = [:]
        var ledger = ImportLedger.load(locations)
        defer { ledger.save() }
        var used = Set<String>()
        for skill in chosen {
            var folder = SkillNaming.slug(skill.name)
            if folder.isEmpty { folder = "skill" }
            var unique = folder
            var n = 2
            while !used.insert(unique).inserted { unique = "\(folder)-\(n)"; n += 1 }
            if !asDrafts, conflict == .skip,
               fm.fileExists(atPath: locations.userSkills.appendingPathComponent(SkillNaming.slug(skill.name)).appendingPathComponent("SKILL.md").path) {
                result.skillsSkipped[skill.name] = "Vision already has a skill named \(SkillNaming.slug(skill.name)); kept that one."
                continue
            }
            let target = staging.appendingPathComponent(unique)
            switch stage(skill, into: target, problems: &result.problems) {
            case .success:
                let hash = folderHash(target)
                if !asDrafts, ledger.isCurrent(ledgerKey(skill), hash: hash, skills: locations.userSkills) {
                    result.skillsSkipped[skill.name] = "Already in Vision, unchanged since it was brought in."
                    continue
                }
                staged[unique] = skill
                hashes[unique] = hash
            case .failure(let refusal): result.skillsSkipped[skill.name] = refusal.message
            }
        }
        guard !staged.isEmpty else { return }
        do {
            let plan = try SkillImporter.scan(staging)
            defer { SkillImporter.dispose(plan) }
            func folderOf(_ candidate: ImportCandidate) -> String {
                URL(fileURLWithPath: candidate.id).deletingLastPathComponent().lastPathComponent
            }
            let mine = plan.candidates.filter { staged[folderOf($0)] != nil }
            let policy: ConflictPolicy = conflict == .replace ? .replace : .rename
            let performed = try SkillImporter.perform(plan, selecting: Set(mine.map(\.id)), scope: .user, projectRoot: nil,
                                                      asDraft: asDrafts, conflict: policy, locations: locations)
            for (name, why) in performed.skipped { result.skillsSkipped[name] = why }
            for candidate in mine where performed.skipped[candidate.skill.name] == nil {
                let folder = folderOf(candidate)
                let original = staged[folder]?.name ?? candidate.skill.name
                if asDrafts {
                    result.skillDrafts.append(original)
                } else {
                    result.skills.append(original)
                    if let skill = staged[folder], let hash = hashes[folder],
                       let slug = landedFolder(performed, skillName: candidate.skill.name) {
                        ledger.record(ledgerKey(skill), hash: hash, slug: slug)
                    }
                }
            }
            for (folder, skill) in staged where !mine.contains(where: { folderOf($0) == folder }) && result.skillsSkipped[skill.name] == nil {
                result.skillsSkipped[skill.name] = "Vision couldn't read it as a skill."
            }
            result.problems.append(contentsOf: plan.notes)
        } catch {
            result.problems.append("Skills stopped part-way: \(error.localizedDescription)")
        }
    }

    static func ledgerKey(_ skill: OpenClawSkill) -> String { "This Mac|" + skill.directory.path }

    /// The folder a skill landed in, from the paths the importer reports.
    static func landedFolder(_ result: ImportResult, skillName: String) -> String? {
        let slug = SkillNaming.slug(skillName)
        for url in result.imported {
            let folder = url.deletingLastPathComponent().lastPathComponent
            if folder.caseInsensitiveCompare(slug) == .orderedSame || folder.lowercased().hasPrefix(slug.lowercased() + "-") { return folder }
        }
        return nil
    }

    /// A fingerprint of a folder's files (names and bytes), to tell whether a skill changed at its source — the
    /// same as Vision for Windows: SHA-256 over "relative/path\0" + bytes in path order, first 12 bytes in hex.
    static func folderHash(_ folder: URL) -> String {
        var hasher = SHA256()
        for relative in OpenClawReader.listFiles(folder, maxDepth: 12, limit: 10_000).sorted() {
            hasher.update(data: Data((relative + "\0").utf8))
            if let data = try? Data(contentsOf: folder.appendingPathComponent(relative)) { hasher.update(data: data) }
        }
        return hasher.finalize().prefix(12).map { String(format: "%02X", $0) }.joined()
    }

    /// What was brought in from where (openclaw-imports.json beside the skills, the same file and shape as Vision for
    /// Windows), so bringing the same unchanged skill in again does nothing instead of adding a "-2" copy.
    struct ImportLedger {
        struct Entry: Codable { var Hash: String; var Slug: String }   // swiftlint:disable:this identifier_name
        let url: URL
        var entries: [String: Entry]
        var dirty = false

        static func load(_ locations: SkillLocations) -> ImportLedger {
            let url = locations.appSupport.appendingPathComponent("openclaw-imports.json")
            var entries: [String: Entry] = [:]
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in raw {
                    if let object = value as? [String: Any], let hash = object["Hash"] as? String, let slug = object["Slug"] as? String {
                        entries[key] = Entry(Hash: hash, Slug: slug)
                    }
                }
            }
            return ImportLedger(url: url, entries: entries)
        }

        func isCurrent(_ key: String, hash: String, skills: URL) -> Bool {
            guard let entry = entries[key], entry.Hash == hash else { return false }
            return FileManager.default.fileExists(atPath: skills.appendingPathComponent(entry.Slug).appendingPathComponent("SKILL.md").path)
        }

        mutating func record(_ key: String, hash: String, slug: String) {
            entries[key] = Entry(Hash: hash, Slug: slug)
            dirty = true
        }

        func save() {
            guard dirty, let data = try? JSONEncoder().encode(entries) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Copy a skill's files into `target`, leaving out credential files and anything with a key inside.
    static func stage(_ skill: OpenClawSkill, into target: URL, problems: inout [String]) -> Result<Void, Refusal> {
        let fm = FileManager.default
        let files = skill.files.filter(isSafeRelative)
            .sorted { lhs, rhs in
                let l = lhs.caseInsensitiveCompare("SKILL.md") == .orderedSame ? 0 : 1
                let r = rhs.caseInsensitiveCompare("SKILL.md") == .orderedSame ? 0 : 1
                return (l, lhs.filter { $0 == "/" }.count, lhs) < (r, rhs.filter { $0 == "/" }.count, rhs)
            }
            .prefix(maxFilesPerSkill)
        guard files.contains(where: { $0.caseInsensitiveCompare("SKILL.md") == .orderedSame }) else {
            return .failure(Refusal(message: "Its SKILL.md is a link to another file, not a file of its own — Vision doesn't follow links out of a skill."))
        }
        if skill.files.count >= maxFilesPerSkill {
            problems.append("Skill “\(skill.name)”: it has \(maxFilesPerSkill) files or more, and only the first \(maxFilesPerSkill) were brought in.")
        }
        var total = 0
        var manifest = false
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for relative in files {
                let isManifest = relative.caseInsensitiveCompare("SKILL.md") == .orderedSame
                let source = skill.directory.appendingPathComponent(relative)
                guard let attributes = try? fm.attributesOfItem(atPath: source.path),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let size = attributes[.size] as? Int, size <= maxBytesPerFile,
                      let data = try? Data(contentsOf: source) else {
                    if !isManifest { problems.append("Skill “\(skill.name)”: \(relative) couldn't be read, or is larger than 1.5 MB, so it was left out.") }
                    continue
                }
                if isCredentialFile(relative) {
                    problems.append("Skill “\(skill.name)”: left out \(relative) — it looks like it holds credentials. Add them to the vault instead.")
                    continue
                }
                if !data.contains(0), let text = String(data: data, encoding: .utf8), !secretDetector.matches(in: text).isEmpty {
                    if isManifest {
                        return .failure(Refusal(message: "SKILL.md contains what looks like a key or a password. Take it out (keys belong in the vault) and try again."))
                    }
                    problems.append("Skill “\(skill.name)”: left out \(relative) — it contains what looks like a key or a password.")
                    continue
                }
                total += data.count
                if total > maxBytesPerSkill { return .failure(Refusal(message: "It is larger than 5 MB.")) }
                let destination = target.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
                if isManifest { manifest = true }
            }
        } catch {
            return .failure(Refusal(message: "Couldn't copy it: \(error.localizedDescription)"))
        }
        return manifest ? .success(()) : .failure(Refusal(message: "Its SKILL.md couldn't be read."))
    }
}

// MARK: - Export

public struct OpenClawExportSelection: Sendable, Equatable {
    /// Vision skills to send, by skill id (their SKILL.md path).
    public var skills: Set<String> = []
    /// Send ~/MEMORY.md and the daily logs in ~/memory.
    public var memory = false
    /// Vault entries to send, by name. Written only when `vaultConfirmed` is true.
    public var vault: Set<String> = []
    /// The person confirmed writing secrets in plain text to OpenClaw's .env.
    public var vaultConfirmed = false
    public var conflict: OpenClawConflict = .skip

    public init() {}
}

public struct OpenClawExportResult: Sendable, Equatable {
    public var skills: [String] = []
    public var skillsSkipped: [String: String] = [:]
    public var memoryAdded = 0
    public var memoryUpdated = 0
    public var memoryUnchanged = 0
    /// The .env names written (never the values).
    public var secrets: [String] = []
    public var secretsSkipped: [String: String] = [:]
    public var problems: [String] = []

    public var summary: String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        var parts: [String] = []
        if !skills.isEmpty { parts.append(n(skills.count, "skill", "skills")) }
        if memoryAdded + memoryUpdated > 0 { parts.append(n(memoryAdded + memoryUpdated, "memory file", "memory files")) }
        if !secrets.isEmpty { parts.append(n(secrets.count, "key or password", "keys and passwords")) }
        switch parts.count {
        case 0: return "nothing new"
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

public enum OpenClawExporter {
    public static let blockTag = "vision-export"

    /// The workspace memory goes to: the install's first workspace, else <state>/workspace.
    public static func workspace(for install: OpenClawInstall, home: URL) -> URL {
        OpenClawReader.read(install, home: home).workspaces.first ?? install.stateDir.appendingPathComponent("workspace", isDirectory: true)
    }

    /// Send what was chosen to an OpenClaw install. Vault secrets are written only when the selection says the person
    /// confirmed it; otherwise they are listed as skipped.
    public static func export(_ selection: OpenClawExportSelection, to install: OpenClawInstall, home: URL,
                              skills catalog: [Skill], vault: CredentialVault?) -> OpenClawExportResult {
        var result = OpenClawExportResult()
        let fm = FileManager.default
        let state = install.stateDir

        // Skills → <state>/skills (OpenClaw's managed skills; a workspace skill of the same name still wins there).
        let chosen = catalog.filter { selection.skills.contains($0.id) }
        if !chosen.isEmpty {
            let base = state.appendingPathComponent("skills", isDirectory: true)
            for skill in chosen {
                let slug = SkillNaming.slug(skill.name).isEmpty ? "skill" : SkillNaming.slug(skill.name)
                if selection.conflict == .skip, fm.fileExists(atPath: base.appendingPathComponent(slug).path) {
                    result.skillsSkipped[skill.name] = "OpenClaw already has a skill named \(slug); kept that one."
                    continue
                }
                do {
                    let policy: ConflictPolicy = selection.conflict == .replace ? .replace : .rename
                    try SkillExporter.write([skill], format: .portable, into: base, conflict: policy)
                    result.skills.append(skill.name)
                } catch {
                    result.skillsSkipped[skill.name] = error.localizedDescription
                }
            }
        }

        // Memory → the workspace's MEMORY.md and memory/<day>.md, as marked blocks.
        if selection.memory {
            let workspace = workspace(for: install, home: home)
            var sources: [(URL, URL, String, String)] = []
            let memory = home.appendingPathComponent("MEMORY.md")
            if fm.fileExists(atPath: memory.path) {
                sources.append((memory, workspace.appendingPathComponent("MEMORY.md"), "MEMORY.md", "From Vision — MEMORY.md"))
            }
            let daily = home.appendingPathComponent("memory", isDirectory: true)
            for name in OpenClawReader.list(daily) where name.lowercased().hasSuffix(".md") {
                sources.append((daily.appendingPathComponent(name), workspace.appendingPathComponent("memory/\(name)"),
                                "memory/\(name)", "From Vision — memory/\(name)"))
            }
            if sources.isEmpty { result.problems.append("Vision has no memory to send yet (~/MEMORY.md and ~/memory are empty).") }
            for (source, target, name, title) in sources {
                guard var body = try? String(contentsOf: source, encoding: .utf8),
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // What Vision imported from OpenClaw doesn't go back to it.
                body = strippingBlocks(OpenClawImporter.blockTag, from: body)
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if !OpenClawImporter.secretDetector.matches(in: body).isEmpty {
                    result.problems.append("\(name) was left out because it holds what looks like a key or a password.")
                    continue
                }
                do {
                    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                    let (text, outcome) = MarkdownBlocks.upsert(tag: blockTag, name: name, title: title, body: body, into: existing)
                    switch outcome {
                    case .added: result.memoryAdded += 1
                    case .updated: result.memoryUpdated += 1
                    case .unchanged: result.memoryUnchanged += 1
                    }
                    if outcome != .unchanged { try MarkdownBlocks.write(text, to: target) }
                } catch {
                    result.problems.append("\(name) couldn't be written: \(error.localizedDescription)")
                }
            }
        }

        // Vault → <state>/.env, only when confirmed.
        if !selection.vault.isEmpty {
            if !selection.vaultConfirmed || vault == nil {
                for name in selection.vault { result.secretsSkipped[name] = "Not confirmed — keys and passwords are only written after you confirm." }
            } else if let vault {
                writeSecrets(selection.vault.sorted(), from: vault, to: state.appendingPathComponent(".env"), conflict: selection.conflict, into: &result)
            }
        }
        return result
    }

    /// Text with every block of `tag` taken out.
    static func strippingBlocks(_ tag: String, from text: String) -> String {
        var out = text
        while let start = out.range(of: "<!-- \(tag):begin ") {
            guard let lineEnd = out[start.upperBound...].range(of: "-->") else { break }
            let header = out[start.upperBound..<lineEnd.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = header.split(separator: " ").dropLast().joined(separator: " ")
            guard let close = out.range(of: MarkdownBlocks.end(tag, name), range: lineEnd.upperBound..<out.endIndex) else { break }
            out.removeSubrange(start.lowerBound..<close.upperBound)
        }
        return out
    }

    /// Upsert NAME="value" lines into an .env file (mode 0600). Values are never logged; the result names only.
    static func writeSecrets(_ names: [String], from vault: CredentialVault, to file: URL, conflict: OpenClawConflict,
                             into result: inout OpenClawExportResult) {
        let fm = FileManager.default
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var existing: [String: (index: Int, value: String)] = [:]
        for (index, line) in lines.enumerated() {
            if let (name, value) = OpenClawReader.parseEnv(line).first { existing[name] = (index, value) }
        }
        var changed = false
        for name in names {
            guard let entry = vault.entry(named: name), let value = try? vault.value(for: entry.id), !value.isEmpty else {
                result.secretsSkipped[name] = "It isn't in the vault any more."
                continue
            }
            let envName = OpenClawReader.sanitize(name).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_")
            let line = "\(envName)=\(quoted(value))"
            if let found = existing[envName] {
                if found.value == value {
                    result.secretsSkipped[name] = "OpenClaw already has \(envName) with this value."
                    continue
                }
                switch conflict {
                case .skip:
                    result.secretsSkipped[name] = "OpenClaw already has \(envName) with a different value; kept that one."
                    continue
                case .replace:
                    lines[found.index] = line
                case .keepBoth:
                    var candidate = envName + "_VISION"
                    var n = 2
                    while existing[candidate] != nil { candidate = envName + "_VISION_\(n)"; n += 1 }
                    lines.append("\(candidate)=\(quoted(value))")
                    existing[candidate] = (lines.count - 1, value)
                    result.secrets.append(candidate)
                    changed = true
                    continue
                }
            } else {
                lines.append(line)
                existing[envName] = (lines.count - 1, value)
            }
            result.secrets.append(envName)
            changed = true
        }
        guard changed else { return }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = lines.joined(separator: "\n") + "\n"
            let temp = file.deletingLastPathComponent().appendingPathComponent(".env.vision-\(UUID().uuidString.prefix(8))")
            guard fm.createFile(atPath: temp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if fm.fileExists(atPath: file.path) {
                _ = try fm.replaceItemAt(file, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: file)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            result.problems.append("OpenClaw's .env couldn't be written: \(error.localizedDescription)")
            result.secrets.removeAll()
        }
    }

    /// A dotenv value in double quotes, with backslashes, quotes and line breaks escaped.
    static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }
}
