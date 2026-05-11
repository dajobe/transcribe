import Foundation

enum ConfigCommand {
    static func helpText() -> String {
        """
        OVERVIEW: View or edit user configuration (JSON under the XDG config directory).

        USAGE: transcribe config <subcommand>

        SUBCOMMANDS:
          show              Print effective settings as `key value` lines (sorted per group; display-only; JSON on disk). Optional `#` lines before a key document unset semantics when the displayed value is `(none)` or `(auto)` (same wording as `transcribe --help` for those options).
          get <key>         Print the effective value for one dotted key (e.g. dir.sessionGap).
          set <key> <val>   Set an override ( booleans: true / false ).
          unset <key>       Remove a user override.
          path              Print the resolved config file path.

        Run `transcribe --help` for global transcription options (CLI overrides config).

        Environment:
          XDG_CONFIG_HOME     Base for ~/.config layout when set.
          TRANSCRIBE_CONFIG   Absolute path to config.json (testing).

        """
    }

    static func run(globalArgs _: SharedTranscriptionOptions, argv: [String]) throws {
        guard let sub = argv.first else {
            throw TranscribeError(
                message: "Expected a subcommand: show, get, set, unset, or path. Example: transcribe config show",
                exitCode: .invalidUsage
            )
        }
        let rest = Array(argv.dropFirst())
        switch sub {
        case "show":
            guard rest.isEmpty else {
                throw TranscribeError(message: "Unexpected arguments after `config show`.", exitCode: .invalidUsage)
            }
            try show()
        case "path":
            guard rest.isEmpty else {
                throw TranscribeError(message: "Unexpected arguments after `config path`.", exitCode: .invalidUsage)
            }
            try path()
        case "get":
            guard rest.count == 1 else {
                throw TranscribeError(message: "Usage: transcribe config get <key>", exitCode: .invalidUsage)
            }
            try get(key: rest[0])
        case "set":
            guard rest.count >= 2 else {
                throw TranscribeError(message: "Usage: transcribe config set <key> <value>", exitCode: .invalidUsage)
            }
            let key = rest[0]
            let value = rest.dropFirst().joined(separator: " ")
            try set(key: key, rawValue: value)
        case "unset":
            guard rest.count == 1 else {
                throw TranscribeError(message: "Usage: transcribe config unset <key>", exitCode: .invalidUsage)
            }
            try unset(key: rest[0])
        default:
            throw TranscribeError(message: "Unknown config subcommand '\(sub)'. Try transcribe config show.", exitCode: .invalidUsage)
        }
    }

    private static func path() throws {
        let url = try ConfigPaths.configFileURL()
        print(url.path)
    }

    private static func show() throws {
        let fileURL = try ConfigPaths.configFileURL()
        let disk = try UserConfigFile.loadOrEmpty(from: fileURL)
        let emptyCli = try SharedTranscriptionOptions.parse([])
        let effective = try ConfigMerge.mergeShared(cli: emptyCli, file: disk)
        let dirEff = try ConfigMerge.mergeDirectory(cli: try DirectoryInputOptions.parse([]), file: disk)
        let vmEff = ConfigMerge.mergeVoiceMemos(cli: try VoiceMemosSourceArguments.parse([]), file: disk)

        print(dottedKeyValueShowText(shared: effective, dir: dirEff, vm: vmEff))
    }

    /// Display-only summary: `key value` lines (shell-quoted when needed) matching `config get` / `set` / `unset` names.
    /// Optional `# ...` line immediately before a key documents unset semantics when the displayed value is `(none)` or `(auto)` (not a settable default string).
    /// When the effective value differs from the built-in default, appends `(default DEFAULT)` so overrides are visible.
    /// Groups (blank line between): ultra-common flat keys, `output.*`, `cache.*`, `speakers.*`, `compute.*`, `logging.*`, `dir.*`, `voiceMemos.*`. Sorted within each group.
    /// Not valid pasted as `config set` unless you split key and value; use `config set <key> <value>` or edit `config.json`.
    private static func dottedKeyValueShowText(
        shared: ResolvedSharedOptions,
        dir: ResolvedDirectoryOptions,
        vm: ResolvedVoiceMemosOptions
    ) -> String {
        let rows = catalogRows(shared: shared, dir: dir, vm: vm)
        let sorted = rows.sorted {
            let g0 = configShowGroup(for: $0.dottedKey)
            let g1 = configShowGroup(for: $1.dottedKey)
            if g0 != g1 { return g0 < g1 }
            return $0.dottedKey < $1.dottedKey
        }

        var lines: [String] = []
        var lastGroup = -1
        for row in sorted {
            let g = configShowGroup(for: row.dottedKey)
            if lastGroup != -1, g != lastGroup {
                lines.append("")
            }
            if let comment = row.computedComment {
                lines.append("# \(comment)")
            }
            var line = "\(row.dottedKey) \(shellQuotedConfigValue(row.effectiveRepr))"
            if row.effectiveRepr != row.defaultRepr {
                line += " (default \(shellQuotedConfigValue(row.defaultRepr)))"
            }
            lines.append(line)
            lastGroup = g
        }
        return lines.joined(separator: "\n")
    }

    /// Display order for `config show` (smaller runs first).
    private static func configShowGroup(for dottedKey: String) -> Int {
        if !dottedKey.contains(".") { return 0 }
        if dottedKey.hasPrefix("output.") { return 1 }
        if dottedKey.hasPrefix("cache.") { return 2 }
        if dottedKey.hasPrefix("speakers.") { return 3 }
        if dottedKey.hasPrefix("compute.") { return 4 }
        if dottedKey.hasPrefix("logging.") { return 5 }
        if dottedKey.hasPrefix("dir.") { return 6 }
        if dottedKey.hasPrefix("voiceMemos.") { return 7 }
        return 99
    }

    /// Shell-style quoting for `config show` values (and default annotations) so a pasted token matches `config set <key> <value>`.
    private static func shellQuotedConfigValue(_ value: String) -> String {
        let needsQuotes =
            value.contains(" ")
            || value.contains("\n") || value.contains("\r") || value.contains("#")
            || value.contains(";") || value.contains("=")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.hasPrefix("\t") || value.contains("\"")

        guard needsQuotes else { return value }

        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func get(key: String) throws {
        let fileURL = try ConfigPaths.configFileURL()
        let disk = try UserConfigFile.loadOrEmpty(from: fileURL)
        let emptyCli = try SharedTranscriptionOptions.parse([])
        let effective = try ConfigMerge.mergeShared(cli: emptyCli, file: disk)
        let dirEff = try ConfigMerge.mergeDirectory(cli: try DirectoryInputOptions.parse([]), file: disk)
        let vmEff = ConfigMerge.mergeVoiceMemos(cli: try VoiceMemosSourceArguments.parse([]), file: disk)

        let rows = catalogRows(shared: effective, dir: dirEff, vm: vmEff)
        guard let row = rows.first(where: { $0.dottedKey == key }) else {
            throw TranscribeError(message: "Unknown config key '\(key)'. Run `transcribe config show`.", exitCode: .invalidUsage)
        }
        print(row.effectiveRepr)
    }

    private struct CatalogRow {
        let dottedKey: String
        let effectiveRepr: String
        let defaultRepr: String
        /// Printed as `# comment` on the line before this key when non-nil (unset-display sentinel only).
        let computedComment: String?
    }

    /// Catalog keys for `show` / `get` / `set` / `unset`. Ultra-common: `model`, `format`, `language` (flat); rest grouped with dots.
    private static func catalogRows(
        shared: ResolvedSharedOptions,
        dir: ResolvedDirectoryOptions,
        vm: ResolvedVoiceMemosOptions
    ) -> [CatalogRow] {
        let modelDef = TranscriptionDefaults.defaultModel
        let langDef = "(auto)"
        let fmtDef = TranscriptionDefaults.format
        let outDef = TranscriptionDefaults.outputDir
        let mdDef = TranscriptionDefaults.modelDir
        let mergeDef = TranscriptionDefaults.speakerMerge
        let none = "(none)"

        var rows: [CatalogRow] = []

        func r(_ dotted: String, _ eff: String, _ def: String, comment: String? = nil) {
            rows.append(
                CatalogRow(
                    dottedKey: dotted,
                    effectiveRepr: eff,
                    defaultRepr: def,
                    computedComment: comment
                )
            )
        }

        r("model", shared.model, modelDef)

        let langEff = shared.language ?? langDef
        r(
            "language",
            langEff,
            langDef,
            comment: langEff == langDef ? ConfigSemanticStrings.languageWhenUnset : nil
        )

        r("format", shared.format, fmtDef)
        r("output.dir", shared.outputDir, outDef)

        let prefixEff = shared.outputPrefix ?? none
        r(
            "output.prefix",
            prefixEff,
            none,
            comment: prefixEff == none ? ConfigSemanticStrings.outputPrefixWhenUnset : nil
        )

        r("cache.modelDir", shared.modelDir, mdDef)
        r("speakers.merge", shared.speakerMerge, mergeDef)

        let minEff = shared.minSpeakers.map(String.init) ?? none
        r(
            "speakers.min",
            minEff,
            none,
            comment: minEff == none ? ConfigSemanticStrings.speakersMinWhenUnset : nil
        )

        let maxEff = shared.maxSpeakers.map(String.init) ?? none
        r(
            "speakers.max",
            maxEff,
            none,
            comment: maxEff == none ? ConfigSemanticStrings.speakersMaxWhenUnset : nil
        )
        r("compute.audioEncoder", shared.audioEncoderCompute.rawValue, TranscriptionDefaults.audioEncoderCompute.rawValue)
        r("compute.textDecoder", shared.textDecoderCompute.rawValue, TranscriptionDefaults.textDecoderCompute.rawValue)
        r("compute.segmenter", shared.segmenterCompute.rawValue, TranscriptionDefaults.segmenterCompute.rawValue)
        r("compute.embedder", shared.embedderCompute.rawValue, TranscriptionDefaults.embedderCompute.rawValue)
        r("speakers.enabled", boolStr(shared.speakersEnabled), boolStr(TranscriptionDefaults.speakersEnabled))
        r("logging.verbose", boolStr(shared.verbose), boolStr(TranscriptionDefaults.verbose))
        r("logging.etaHints", boolStr(shared.timingStatsPreference), boolStr(TranscriptionDefaults.etaHintsEnabled))
        r("logging.progressLog", shared.progressLogMode.rawValue, TranscriptionDefaults.progressLogMode.rawValue)

        r("dir.sort", dir.sort.rawValue, TranscriptionDefaults.dirSort.rawValue)
        r("dir.sessionGap", String(dir.sessionGap), String(TranscriptionDefaults.dirSessionGapMinutes))
        r("dir.inputTimeSource", dir.inputTimeSource.rawValue, TranscriptionDefaults.dirInputTimeSource.rawValue)
        r("dir.sessionNaming", dir.sessionNaming.rawValue, TranscriptionDefaults.dirSessionNaming.rawValue)

        r("voiceMemos.recordingsDir", vm.recordingsDir, TranscriptionDefaults.voiceMemosRecordingsDir)
        r("voiceMemos.sessionGap", String(vm.sessionGap), String(TranscriptionDefaults.voiceMemosSessionGapMinutes))

        return rows
    }

    private static func boolStr(_ b: Bool) -> String { b ? "true" : "false" }

    private static func set(key: String, rawValue: String) throws {
        var cfg = try UserConfigFile.loadOrEmpty(from: ConfigPaths.configFileURL())
        try applySet(to: &cfg, key: key, rawValue: rawValue)
        try UserConfigFile.save(cfg, to: ConfigPaths.configFileURL())
    }

    private static func unset(key: String) throws {
        var cfg = try UserConfigFile.loadOrEmpty(from: ConfigPaths.configFileURL())
        guard unsetField(on: &cfg, dottedKey: key) else {
            throw TranscribeError(message: "Unknown config key '\(key)'.", exitCode: .invalidUsage)
        }
        try UserConfigFile.save(cfg, to: ConfigPaths.configFileURL())
    }

    /// Returns false if key unknown.
    private static func unsetField(on cfg: inout UserConfigFile, dottedKey: String) -> Bool {
        switch dottedKey {
        case "model": cfg.model = nil
        case "language": cfg.language = nil
        case "format": cfg.format = nil
        case "output.dir":
            guard var o = cfg.output else { return true }
            o.dir = nil
            cfg.output = pruneOutputSection(o)
        case "output.prefix":
            guard var o = cfg.output else { return true }
            o.prefix = nil
            cfg.output = pruneOutputSection(o)
        case "cache.modelDir":
            cfg.cache = nil
        case "speakers.enabled":
            guard var s = cfg.speakers else { return true }
            s.enabled = nil
            cfg.speakers = pruneSpeakersSection(s)
        case "speakers.merge":
            guard var s = cfg.speakers else { return true }
            s.merge = nil
            cfg.speakers = pruneSpeakersSection(s)
        case "speakers.min":
            guard var s = cfg.speakers else { return true }
            s.min = nil
            cfg.speakers = pruneSpeakersSection(s)
        case "speakers.max":
            guard var s = cfg.speakers else { return true }
            s.max = nil
            cfg.speakers = pruneSpeakersSection(s)
        case "compute.audioEncoder":
            guard var c = cfg.compute else { return true }
            c.audioEncoder = nil
            cfg.compute = pruneComputeSection(c)
        case "compute.textDecoder":
            guard var c = cfg.compute else { return true }
            c.textDecoder = nil
            cfg.compute = pruneComputeSection(c)
        case "compute.segmenter":
            guard var c = cfg.compute else { return true }
            c.segmenter = nil
            cfg.compute = pruneComputeSection(c)
        case "compute.embedder":
            guard var c = cfg.compute else { return true }
            c.embedder = nil
            cfg.compute = pruneComputeSection(c)
        case "logging.verbose":
            guard var l = cfg.logging else { return true }
            l.verbose = nil
            cfg.logging = pruneLoggingSection(l)
        case "logging.etaHints":
            guard var l = cfg.logging else { return true }
            l.etaHints = nil
            cfg.logging = pruneLoggingSection(l)
        case "logging.progressLog":
            guard var l = cfg.logging else { return true }
            l.progressLog = nil
            cfg.logging = pruneLoggingSection(l)
        case "dir.sort":
            guard var d = cfg.dir else { return true }
            d.sort = nil
            cfg.dir = pruneDirSection(d)
        case "dir.sessionGap":
            guard var d = cfg.dir else { return true }
            d.sessionGap = nil
            cfg.dir = pruneDirSection(d)
        case "dir.inputTimeSource":
            guard var d = cfg.dir else { return true }
            d.inputTimeSource = nil
            cfg.dir = pruneDirSection(d)
        case "dir.sessionNaming":
            guard var d = cfg.dir else { return true }
            d.sessionNaming = nil
            cfg.dir = pruneDirSection(d)
        case "voiceMemos.recordingsDir":
            guard var vm = cfg.voiceMemos else { return true }
            vm.recordingsDir = nil
            cfg.voiceMemos = pruneVoiceMemosSection(vm)
        case "voiceMemos.sessionGap":
            guard var vm = cfg.voiceMemos else { return true }
            vm.sessionGap = nil
            cfg.voiceMemos = pruneVoiceMemosSection(vm)
        default: return false
        }
        return true
    }

    private static func pruneDirSection(_ d: UserConfigFile.DirSection) -> UserConfigFile.DirSection? {
        if d.sort == nil && d.sessionGap == nil && d.inputTimeSource == nil && d.sessionNaming == nil {
            return nil
        }
        return d
    }

    private static func pruneVoiceMemosSection(_ vm: UserConfigFile.VoiceMemosSection) -> UserConfigFile.VoiceMemosSection? {
        if vm.recordingsDir == nil && vm.sessionGap == nil {
            return nil
        }
        return vm
    }

    private static func pruneOutputSection(_ o: UserConfigFile.OutputSection) -> UserConfigFile.OutputSection? {
        if o.dir == nil && o.prefix == nil { return nil }
        return o
    }

    private static func pruneSpeakersSection(_ s: UserConfigFile.SpeakersSection) -> UserConfigFile.SpeakersSection? {
        if s.enabled == nil && s.merge == nil && s.min == nil && s.max == nil { return nil }
        return s
    }

    private static func pruneComputeSection(_ c: UserConfigFile.ComputeSection) -> UserConfigFile.ComputeSection? {
        if c.audioEncoder == nil && c.textDecoder == nil && c.segmenter == nil && c.embedder == nil { return nil }
        return c
    }

    private static func pruneLoggingSection(_ l: UserConfigFile.LoggingSection) -> UserConfigFile.LoggingSection? {
        if l.verbose == nil && l.etaHints == nil && l.progressLog == nil { return nil }
        return l
    }

    private static func applySet(to cfg: inout UserConfigFile, key: String, rawValue: String) throws {
        let v = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "model":
            cfg.model = v
        case "language":
            cfg.language = v.isEmpty ? nil : v
        case "format":
            cfg.format = v
        case "output.dir":
            var o = cfg.output ?? UserConfigFile.OutputSection()
            o.dir = v
            cfg.output = o
        case "output.prefix":
            var o = cfg.output ?? UserConfigFile.OutputSection()
            o.prefix = v.isEmpty ? nil : v
            cfg.output = o
        case "cache.modelDir":
            var c = cfg.cache ?? UserConfigFile.CacheSection()
            c.modelDir = v
            cfg.cache = c
        case "speakers.enabled":
            var s = cfg.speakers ?? UserConfigFile.SpeakersSection()
            s.enabled = try parseTriBool(v)
            cfg.speakers = s
        case "speakers.merge":
            var s = cfg.speakers ?? UserConfigFile.SpeakersSection()
            s.merge = v
            cfg.speakers = s
        case "speakers.min":
            var s = cfg.speakers ?? UserConfigFile.SpeakersSection()
            s.min = try parseOptionalInt(v)
            cfg.speakers = s
        case "speakers.max":
            var s = cfg.speakers ?? UserConfigFile.SpeakersSection()
            s.max = try parseOptionalInt(v)
            cfg.speakers = s
        case "compute.audioEncoder":
            var c = cfg.compute ?? UserConfigFile.ComputeSection()
            try validateCompute(v)
            c.audioEncoder = v
            cfg.compute = c
        case "compute.textDecoder":
            var c = cfg.compute ?? UserConfigFile.ComputeSection()
            try validateCompute(v)
            c.textDecoder = v
            cfg.compute = c
        case "compute.segmenter":
            var c = cfg.compute ?? UserConfigFile.ComputeSection()
            try validateCompute(v)
            c.segmenter = v
            cfg.compute = c
        case "compute.embedder":
            var c = cfg.compute ?? UserConfigFile.ComputeSection()
            try validateCompute(v)
            c.embedder = v
            cfg.compute = c
        case "logging.verbose":
            var l = cfg.logging ?? UserConfigFile.LoggingSection()
            l.verbose = try parseTriBool(v)
            cfg.logging = l
        case "logging.etaHints":
            var l = cfg.logging ?? UserConfigFile.LoggingSection()
            l.etaHints = try parseTriBool(v)
            cfg.logging = l
        case "logging.progressLog":
            var l = cfg.logging ?? UserConfigFile.LoggingSection()
            l.progressLog = try parseProgressLogRaw(v)
            cfg.logging = l
        case "dir.sort":
            var d = cfg.dir ?? UserConfigFile.DirSection()
            d.sort = v
            cfg.dir = d
        case "dir.sessionGap":
            var d = cfg.dir ?? UserConfigFile.DirSection()
            d.sessionGap = try parseIntNonNil(v)
            cfg.dir = d
        case "dir.inputTimeSource":
            var d = cfg.dir ?? UserConfigFile.DirSection()
            d.inputTimeSource = try parseInputTimeSourceRaw(v)
            cfg.dir = d
        case "dir.sessionNaming":
            var d = cfg.dir ?? UserConfigFile.DirSection()
            d.sessionNaming = try parseSessionNamingRaw(v)
            cfg.dir = d
        case "voiceMemos.recordingsDir":
            var vm = cfg.voiceMemos ?? UserConfigFile.VoiceMemosSection()
            vm.recordingsDir = v
            cfg.voiceMemos = vm
        case "voiceMemos.sessionGap":
            var vm = cfg.voiceMemos ?? UserConfigFile.VoiceMemosSection()
            vm.sessionGap = try parseIntNonNil(v)
            cfg.voiceMemos = vm
        default:
            throw TranscribeError(message: "Unknown config key '\(key)'.", exitCode: .invalidUsage)
        }
    }

    /// Optional boolean for JSON-like overrides (`null` / clear removes override when supported by caller).
    private static func parseTriBool(_ s: String) throws -> Bool? {
        let l = s.lowercased()
        if l == "null" || l == "clear" || l == "omit" { return nil }
        if l == "true" || l == "1" || l == "yes" { return true }
        if l == "false" || l == "0" || l == "no" { return false }
        throw TranscribeError(message: "Expected boolean (true/false), null, or omit.", exitCode: .invalidUsage)
    }

    private static func parseBoolNonNil(_ s: String) throws -> Bool {
        guard let b = try parseTriBool(s) else {
            throw TranscribeError(message: "Expected true or false.", exitCode: .invalidUsage)
        }
        return b
    }

    private static func parseOptionalInt(_ s: String) throws -> Int? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "none" || t.lowercased() == "null" { return nil }
        guard let i = Int(t) else {
            throw TranscribeError(message: "Expected integer or none.", exitCode: .invalidUsage)
        }
        return i
    }

    private static func parseIntNonNil(_ s: String) throws -> Int {
        guard let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TranscribeError(message: "Expected integer.", exitCode: .invalidUsage)
        }
        return i
    }

    private static func validateCompute(_ s: String) throws {
        guard ComputeUnitsOption(rawValue: s) != nil else {
            throw TranscribeError(message: "Invalid compute units '\(s)'.", exitCode: .invalidUsage)
        }
    }

    private static func parseProgressLogRaw(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ProgressLogMode(rawValue: t) != nil else {
            throw TranscribeError(message: "Expected logging.progressLog auto, plain, or off.", exitCode: .invalidUsage)
        }
        return t
    }

    private static func parseInputTimeSourceRaw(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard InputTimeSource(rawValue: t) != nil else {
            throw TranscribeError(
                message: "Expected dir.inputTimeSource auto, embedded, filename, or off.",
                exitCode: .invalidUsage
            )
        }
        return t
    }

    private static func parseSessionNamingRaw(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SessionNamingMode(rawValue: t) != nil else {
            throw TranscribeError(message: "Expected dir.sessionNaming auto, clip, or off.", exitCode: .invalidUsage)
        }
        return t
    }
}
