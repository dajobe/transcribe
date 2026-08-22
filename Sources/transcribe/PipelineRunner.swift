import Foundation
import SpeakerKit
import WhisperKit
#if canImport(Darwin)
import Darwin
#endif

enum SourceMode {
    case file
    case directory
    case voiceMemos
}

enum PipelineRequest {
    case file(path: String)
    case directory(path: String, options: ResolvedDirectoryOptions)
    case voiceMemos(recordingsDir: String, sessionGap: Int)
}

struct PipelineSessionPlan {
    let session: AudioSession
    let basename: String
    let audioPathForOutput: String
    let audioFilesForOutput: [String]?
    let sourceKind: ProcessingSourceKind
    let sourceID: String
    let sourceMetadata: OutputSourceMetadata?
}

struct PipelineWorkItem {
    let plan: PipelineSessionPlan
    let sessionIndex: Int
    let sessionTotal: Int
    let fingerprint: SourceFingerprint
    let outputPaths: [String]
    let historyReason: ProcessingHistoryReason
    let recordsSkipHistory: Bool
}

private enum PipelineOutputMode {
    case tui
    case eventLog
    case off

    static func resolve(_ progressLogMode: ProgressLogMode) -> PipelineOutputMode {
        switch progressLogMode {
        case .plain:
            return .eventLog
        case .off:
            return .off
        case .auto:
            return isStdoutTTY() ? .tui : .eventLog
        }
    }
}

enum SourcePlanner {
    /// Resolve a root path alias (`transcribe <path>`) to a file or directory
    /// dispatch mode. Symlinks are followed: a path pointing at a directory
    /// symlink is treated as a directory source. Use the explicit `file` or
    /// `dir` subcommands if you need to disambiguate or restrict the kind.
    static func modeForAliasPath(_ rawPath: String) throws -> SourceMode {
        let expanded = (rawPath as NSString).expandingTildeInPath
        warnIfSymlink(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw TranscribeError(message: "Input does not exist: \(rawPath)", exitCode: .inputFile)
        }
        return isDir.boolValue ? .directory : .file
    }

    static func validateFilePath(_ rawPath: String) throws {
        let expanded = (rawPath as NSString).expandingTildeInPath
        warnIfSymlink(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw TranscribeError(message: "Input does not exist: \(rawPath)", exitCode: .inputFile)
        }
        if isDir.boolValue {
            throw TranscribeError(message: "`transcribe file` requires an audio file, got directory: \(rawPath)", exitCode: .invalidUsage)
        }
    }

    static func validateDirectoryPath(_ rawPath: String) throws {
        let expanded = (rawPath as NSString).expandingTildeInPath
        warnIfSymlink(expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw TranscribeError(message: "Input does not exist: \(rawPath)", exitCode: .inputFile)
        }
        if !isDir.boolValue {
            throw TranscribeError(message: "`transcribe dir` requires a directory, got file: \(rawPath)", exitCode: .invalidUsage)
        }
    }

    private static func warnIfSymlink(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            emitWarning("Input path is a symlink: \(path)")
        }
    }

    static func filePlan(path: String, outputPrefix: String?) -> [PipelineSessionPlan] {
        let resolved = ResolvedInput.file(path: (path as NSString).expandingTildeInPath)
        let basename = InputResolver.sessionBasenames(for: resolved, prefixOverride: outputPrefix)[0]
        let expanded = (path as NSString).expandingTildeInPath
        return [
            PipelineSessionPlan(
                session: AudioSession(files: [expanded], recordedAt: nil),
                basename: basename,
                audioPathForOutput: expanded,
                audioFilesForOutput: nil,
                sourceKind: .file,
                sourceID: sourceIDForFiles(kind: .file, files: [expanded]),
                sourceMetadata: nil
            )
        ]
    }

    static func directoryPlans(
        path: String,
        options: ResolvedDirectoryOptions,
        outputPrefix: String?,
        logger: VerboseLogger
    ) async throws -> [PipelineSessionPlan] {
        let sessionGapSeconds = Double(options.sessionGap) * 60.0
        let resolvedInput = try await InputResolver.resolve(
            path,
            sort: options.sort,
            sessionGapSeconds: sessionGapSeconds,
            filenameTimeRecovery: options.filenameTimeRecovery,
            logger: logger
        )
        guard case .directory(let dirPath, let sessions) = resolvedInput else {
            throw TranscribeError(message: "`transcribe dir` requires a directory, got file: \(path)", exitCode: .invalidUsage)
        }

        let totalClips = sessions.reduce(0) { $0 + $1.files.count }
        logger.log(
            "Input is a directory: \(totalClips) audio file\(totalClips == 1 ? "" : "s"), "
            + "\(sessions.count) session\(sessions.count == 1 ? "" : "s") "
            + "(sort=\(options.sort.rawValue), session-gap=\(options.sessionGap)m)"
        )

        let basenames = InputResolver.sessionBasenames(
            for: resolvedInput,
            prefixOverride: outputPrefix,
            autoSessionBasename: options.autoSessionBasename
        )
        return zip(sessions, basenames).map { (session, basename) in
            PipelineSessionPlan(
                session: session,
                basename: basename,
                audioPathForOutput: dirPath,
                audioFilesForOutput: session.files.map { ($0 as NSString).lastPathComponent },
                sourceKind: .directorySession,
                sourceID: sourceIDForFiles(kind: .directorySession, files: session.files),
                sourceMetadata: nil
            )
        }
    }

    static func voiceMemoPlans(
        recordingsDir: String,
        sessionGap: Int,
        outputPrefix: String?,
        logger: VerboseLogger
    ) throws -> [PipelineSessionPlan] {
        let recordings = try VoiceMemosImport.loadRecordings(recordingsDirectory: recordingsDir, logger: logger)
        let clips = recordings.map {
            AudioClip(path: $0.path, recordedAt: $0.recordedAt, durationSeconds: $0.durationSeconds)
        }
        let sessions = SessionGrouper.groupIntoSessions(
            clips,
            maxGapSeconds: Double(sessionGap) * 60.0,
            logger: logger
        )
        let recordingsByPath = Dictionary(uniqueKeysWithValues: recordings.map { ($0.path, $0) })
        let groupedRecordings = sessions.map { session in
            session.files.compactMap { recordingsByPath[$0] }
        }
        let basenames = VoiceMemosImport.sessionBasenames(for: groupedRecordings, prefixOverride: outputPrefix)
        logger.log(
            "Voice Memos: planned \(sessions.count) session\(sessions.count == 1 ? "" : "s") "
            + "from \(recordings.count) recording\(recordings.count == 1 ? "" : "s") "
            + "(session-gap=\(sessionGap)m)"
        )

        return Array(zip(zip(sessions, groupedRecordings), basenames)).enumerated().map { indexed in
            let (index, combined) = indexed
            let ((session, group), basename) = combined
            let single = group.count == 1 ? group[0] : nil
            return PipelineSessionPlan(
                session: session,
                basename: basename,
                audioPathForOutput: single?.path ?? (recordingsDir as NSString).expandingTildeInPath,
                audioFilesForOutput: group.count > 1 ? group.map { ($0.path as NSString).lastPathComponent } : nil,
                sourceKind: .voiceMemos,
                sourceID: single?.sourceID ?? sourceIDForFiles(kind: .voiceMemos, files: session.files),
                sourceMetadata: VoiceMemosImport.outputMetadata(for: group, sessionIndex: index + 1)
            )
        }
    }
}

struct PipelineRunner {
    let request: PipelineRequest
    let options: ResolvedSharedOptions

    func run() async throws {
        try validateSharedUsage()
        let startDate = Date()
        let outputMode = PipelineOutputMode.resolve(options.progressLogMode)
        var activeReporter: TranscribeEventReporter? = nil
        if !options.dryRun, outputMode != .tui {
            activeReporter = TranscribeEventReporter(
                statusEnabled: outputMode == .eventLog,
                minimumLevel: options.logLevel
            )
        }
        TranscribeEventReporter.setCurrent(activeReporter)
        var logger = VerboseLogger(verbose: options.verbose, startDate: startDate, reporter: activeReporter)

        let sessionPlans = try await buildSessionPlans(logger: logger)
        if options.markImported {
            var workItems: [PipelineWorkItem] = []
            var skippedItems: [PipelineWorkItem] = []
            for (idx, plan) in sessionPlans.enumerated() {
                let fingerprint = try ProcessingStore.fingerprint(files: plan.session.files)
                let decision = try ProcessingStore.importedBaselineDecision(sourceID: plan.sourceID, fingerprint: fingerprint)
                if decision.shouldSkip {
                    let item = PipelineWorkItem(
                        plan: plan,
                        sessionIndex: idx,
                        sessionTotal: sessionPlans.count,
                        fingerprint: fingerprint,
                        outputPaths: [],
                        historyReason: decision.reason,
                        recordsSkipHistory: decision.recordsSkipHistory
                    )
                    skippedItems.append(item)
                } else {
                    let item = PipelineWorkItem(
                        plan: plan,
                        sessionIndex: idx,
                        sessionTotal: sessionPlans.count,
                        fingerprint: fingerprint,
                        outputPaths: [],
                        historyReason: .imported,
                        recordsSkipHistory: false
                    )
                    workItems.append(item)
                }
            }
            if options.dryRun {
                emitDryRunMarkImported(workItems: workItems, skippedItems: skippedItems)
            } else {
                try appendSkipRecords(workItems: skippedItems, settings: nil)
                emitSkippedSessions(skippedItems, reporter: activeReporter)
                try markPlannedInputsImported(workItems: workItems, reporter: activeReporter)
                activeReporter?.info(
                    "run_done",
                    fields: [
                        TranscribeEventField("processed", .int(workItems.count)),
                        TranscribeEventField("skipped", .int(skippedItems.count)),
                        TranscribeEventField("elapsed_s", .double(Date().timeIntervalSince(startDate))),
                    ],
                    message: "mark imported complete"
                )
            }
            return
        }

        let (resolvedModel, modelSelectionSource) = resolvedModelSelection()
        let settingsSignature = ProcessingSettingsSignature(
            model: resolvedModel,
            language: options.language,
            diarization_enabled: options.speakersEnabled,
            speaker_strategy: options.speakerMerge,
            min_speakers: options.minSpeakers,
            max_speakers: options.maxSpeakers,
            formats: options.resolvedFormats,
            transcribe_version: Transcribe.version
        )

        var workItems: [PipelineWorkItem] = []
        var skippedItems: [PipelineWorkItem] = []
        for (idx, plan) in sessionPlans.enumerated() {
            let fingerprint = try ProcessingStore.fingerprint(files: plan.session.files)
            let paths = outputPaths(
                outputDir: options.outputDir,
                basename: plan.basename,
                formats: options.resolvedFormats,
                writeTxtFile: options.wantsTxt
            )
            let decision = try processingDecision(plan: plan, fingerprint: fingerprint, settings: settingsSignature, outputPaths: paths)
            let item = PipelineWorkItem(
                plan: plan,
                sessionIndex: idx,
                sessionTotal: sessionPlans.count,
                fingerprint: fingerprint,
                outputPaths: paths,
                historyReason: decision.reason,
                recordsSkipHistory: decision.recordsSkipHistory
            )
            if decision.shouldSkip {
                logger.log("Skipping already processed input: \(plan.basename)")
                skippedItems.append(item)
                continue
            }
            workItems.append(item)
        }

        if options.dryRun {
            emitDryRun(workItems: workItems, skippedItems: skippedItems)
            return
        }

        try appendSkipRecords(workItems: skippedItems, settings: settingsSignature)
        emitSkippedSessions(skippedItems, reporter: activeReporter)

        if workItems.isEmpty {
            logger.log("No new work to process.")
            activeReporter?.info(
                "run_done",
                fields: [
                    TranscribeEventField("processed", .int(0)),
                    TranscribeEventField("skipped", .int(skippedItems.count)),
                    TranscribeEventField("elapsed_s", .double(Date().timeIntervalSince(startDate))),
                ],
                message: "no new work"
            )
            return
        }

        let historicalRatios: HistoricalTimingRatios = {
            guard options.timingStatsEnabled else { return HistoricalTimingRatios() }
            let totalRecords = (try? TimingStore.loadRecent(
                model: resolvedModel,
                diarizationEnabled: options.speakersEnabled
            )) ?? []
            let phaseRecords = (try? TimingStore.loadRecent(model: resolvedModel)) ?? []
            return TimingStore.historicalRatios(totalRecords: totalRecords, phaseRecords: phaseRecords)
        }()
        let historicalRatio = historicalRatios.totalSecondsPerAudioSecond

        let liveProgressMode: LiveProgressRenderMode? = {
            outputMode == .tui ? .tty : nil
        }()

        let sharedLiveDisplay: LiveProgressDisplay? = {
            guard workItems.count == 1, let mode = liveProgressMode else { return nil }
            return LiveProgressDisplay(
                startDate: startDate,
                stderr: .standardOutput,
                showDiarizationLine: options.speakersEnabled,
                contextLines: progressContextLines(
                    item: workItems[0],
                    model: resolvedModel,
                    outputDir: resolvedOutputDir(options.outputDir)
                ),
                audioDurationSeconds: estimatedAudioDurationSeconds(for: workItems[0].plan) ?? 0,
                historicalRatios: historicalRatios,
                historicalWallSecondsPerAudioSecond: historicalRatio,
                renderMode: mode
            )
        }()

        if outputMode == .tui, let display = sharedLiveDisplay {
            let tuiReporter = TranscribeEventReporter(
                statusEnabled: false,
                minimumLevel: options.logLevel,
                textOutputEnabled: false,
                diagnosticsSink: { event in
                    display.appendDiagnostic(event)
                },
                failureSink: { _ in
                    display.fail()
                }
            )
            activeReporter = tuiReporter
            TranscribeEventReporter.setCurrent(tuiReporter)
            logger = VerboseLogger(verbose: options.verbose, startDate: startDate, reporter: tuiReporter)
        }

        emitModelSelection(model: resolvedModel, source: modelSelectionSource, reporter: activeReporter)

        for item in workItems {
            try checkOverwrite(
                outputDir: options.outputDir,
                basename: item.plan.basename,
                formats: options.resolvedFormats,
                writeTxtFile: options.wantsTxt,
                overwrite: options.overwrite
            )
        }
        sharedLiveDisplay?.beginAudioChecking()
        let inputCheckStart = Date()
        try preflightAudioDecoding(
            for: workItems.map(\.plan.session),
            limits: options.audioLoadLimits,
            logger: logger
        )
        sharedLiveDisplay?.finishAudioChecking()
        activeReporter?.info(
            "phase_done",
            fields: [
                TranscribeEventField("phase", .string("input_check")),
                TranscribeEventField("elapsed_s", .double(Date().timeIntervalSince(inputCheckStart))),
            ],
            message: "input checked"
        )

        sharedLiveDisplay?.beginModelLoading()
        let modelLoadStart = Date()
        let computeOptions = RuntimeComputeOptions.resolve(
            audioEncoder: options.audioEncoderCompute,
            textDecoder: options.textDecoderCompute,
            segmenter: options.segmenterCompute,
            embedder: options.embedderCompute
        )
        let strategy = SpeakerInfoStrategy(from: options.speakerMerge) ?? .subsegment
        let (models, whisperInitMs, speakerInitMs) = try await loadModels(
            model: resolvedModel,
            modelDir: options.modelDir,
            diarize: options.speakersEnabled,
            computeOptions: computeOptions,
            verbose: options.verbose,
            logger: logger
        )
        sharedLiveDisplay?.finishModelLoading()
        activeReporter?.info(
            "phase_done",
            fields: [
                TranscribeEventField("phase", .string("model_loading")),
                TranscribeEventField("elapsed_s", .double(Date().timeIntervalSince(modelLoadStart))),
                TranscribeEventField("model", .string(resolvedModel)),
            ],
            message: "model loaded"
        )

        let resolvedDir = resolvedOutputDir(options.outputDir)

        for (processedIndex, item) in workItems.enumerated() {
            let plan = item.plan
            let session = plan.session
            let sessionStartDate = Date()
            let basename = plan.basename
            activeReporter?.info(
                "session_start",
                fields: sessionFields(
                    item: item,
                    outputDir: resolvedDir
                ),
                message: "session started"
            )
            if workItems.count > 1 {
                logger.log("--- Session \(item.sessionIndex + 1)/\(max(item.sessionTotal, 1)): \(basename) (\(session.files.count) clip\(session.files.count == 1 ? "" : "s")) ---")
            }

            let (preparedAudio, loadMs): (PreparedAudio, Int64)
            sharedLiveDisplay?.beginAudioLoading()
            if session.files.count == 1 {
                (preparedAudio, loadMs) = try WallClock.measureMs {
                    try loadPreparedAudio(
                        audioPath: session.files[0],
                        limits: options.audioLoadLimits,
                        logger: logger
                    )
                }
            } else {
                (preparedAudio, loadMs) = try WallClock.measureMs {
                    try loadPreparedAudio(
                        fromFiles: session.files,
                        limits: options.audioLoadLimits,
                        logger: logger
                    )
                }
            }
            sharedLiveDisplay?.finishAudioLoading(durationSeconds: preparedAudio.durationSeconds)
            activeReporter?.info(
                "phase_done",
                fields: sessionFields(
                    item: item,
                    outputDir: resolvedDir,
                    extra: [
                        TranscribeEventField("phase", .string("audio")),
                        TranscribeEventField("elapsed_s", .double(Double(loadMs) / 1000.0)),
                        TranscribeEventField("audio_duration_s", .double(preparedAudio.durationSeconds)),
                    ]
                ),
                message: "audio loaded"
            )

            let (sessionOutput, sessionPhases) = try await runSession(
                preparedAudio: preparedAudio,
                audioLoadMs: loadMs,
                models: models,
                language: options.language,
                minSpeakers: options.minSpeakers,
                maxSpeakers: options.maxSpeakers,
                speakerStrategy: strategy,
                wordTimestamps: false,
                liveProgressMode: liveProgressMode,
                pipelineStartDate: startDate,
                historicalWallSecondsPerAudioSecond: historicalRatio,
                historicalRatios: historicalRatios,
                liveProgressContextLines: progressContextLines(
                    item: item,
                    model: resolvedModel,
                    outputDir: resolvedDir
                ),
                liveProgressDisplay: sharedLiveDisplay,
                logger: logger
            )
            emitProcessingPhaseEvents(
                phases: sessionPhases,
                item: item,
                outputDir: resolvedDir,
                reporter: activeReporter
            )

            var out = sessionOutput
            out.speakerStrategy = options.speakerMerge
            for warning in out.warnings {
                emitWarning(warning)
            }

            let outputFiles = options.resolvedFormats.map { fmt in "\(basename).\(fmt)" }.joined(separator: ", ")
            logger.log("Writing outputs to \(resolvedDir): \(outputFiles)")

            sharedLiveDisplay?.beginOutput()
            let (_, writeMs) = try WallClock.measureMs {
                try writeOutputs(
                    output: out,
                    audioPath: plan.audioPathForOutput,
                    audioFiles: plan.audioFilesForOutput,
                    sourceMetadata: plan.sourceMetadata,
                    outputDir: options.outputDir,
                    basename: basename,
                    formats: options.resolvedFormats,
                    overwrite: options.overwrite,
                    model: resolvedModel,
                    version: Transcribe.version
                )
            }
            sharedLiveDisplay?.finishOutput()
            activeReporter?.info(
                "phase_done",
                fields: sessionFields(
                    item: item,
                    outputDir: resolvedDir,
                    extra: [
                        TranscribeEventField("phase", .string("output")),
                        TranscribeEventField("elapsed_s", .double(Double(writeMs) / 1000.0)),
                    ]
                ),
                message: "outputs written"
            )
            _ = sharedLiveDisplay?.finish()

            if !options.stateless {
                try ProcessingStore.append(ProcessingRecord(
                    completed_at: iso8601String(Date()),
                    history_reason: item.historyReason,
                    source_kind: plan.sourceKind,
                    source_id: plan.sourceID,
                    source_fingerprint: item.fingerprint,
                    settings_signature: settingsSignature,
                    output_dir: resolvedDir,
                    basename: basename,
                    output_paths: item.outputPaths,
                    audio_duration_s: out.durationSeconds,
                    warning_count: out.warnings.count,
                    recording_title: plan.sourceMetadata?.recordingTitle,
                    recorded_at: plan.sourceMetadata?.recordedAt,
                    voice_memos_unique_id: plan.sourceMetadata?.voiceMemosUniqueID,
                    voice_memos_path: plan.sourceMetadata?.voiceMemosPath
                ))
            }

            if options.timingStatsEnabled {
                let fileBytes: Int64 = session.files.reduce(into: Int64(0)) { total, p in
                    let n = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0
                    total += n
                }
                var phasesForRecord = sessionPhases
                if processedIndex == 0 {
                    phasesForRecord.whisperInitMs = whisperInitMs
                    phasesForRecord.speakerInitMs = speakerInitMs
                }
                let endedAt = Date()
                let timingStartDate = (processedIndex == 0) ? startDate : sessionStartDate
                let totalMs = Int64(endedAt.timeIntervalSince(timingStartDate) * 1000.0)
                let record = RunTimingRecord(
                    endedAt: endedAt,
                    transcribeVersion: Transcribe.version,
                    model: resolvedModel,
                    diarizationEnabled: out.diarizationEnabled,
                    inputBasename: basename,
                    fileBytes: fileBytes,
                    audioDurationS: out.durationSeconds,
                    segmentCount: out.segments.count,
                    speakersDetected: out.speakersDetected,
                    phases: phasesForRecord,
                    writeOutputsMs: writeMs,
                    totalMs: totalMs
                )
                try? TimingStore.append(record)
            }

            activeReporter?.info(
                "session_done",
                fields: sessionFields(
                    item: item,
                    outputDir: resolvedDir,
                    extra: [
                        TranscribeEventField("elapsed_s", .double(Date().timeIntervalSince(sessionStartDate))),
                        TranscribeEventField("audio_duration_s", .double(out.durationSeconds)),
                        TranscribeEventField("segments", .int(out.segments.count)),
                    ]
                ),
                message: "session complete"
            )
        }

        let endedAt = Date()
        let totalSec = Int(endedAt.timeIntervalSince(startDate))
        logger.log("Done. Total: \(totalSec / 60)m \(totalSec % 60)s")
        activeReporter?.info(
            "run_done",
            fields: [
                TranscribeEventField("processed", .int(workItems.count)),
                TranscribeEventField("skipped", .int(skippedItems.count)),
                TranscribeEventField("elapsed_s", .double(endedAt.timeIntervalSince(startDate))),
            ],
            message: "run complete"
        )
    }

    private func buildSessionPlans(logger: VerboseLogger) async throws -> [PipelineSessionPlan] {
        switch request {
        case .file(let path):
            return SourcePlanner.filePlan(path: path, outputPrefix: options.outputPrefix)
        case .directory(let path, let directoryOptions):
            return try await SourcePlanner.directoryPlans(
                path: path,
                options: directoryOptions,
                outputPrefix: options.outputPrefix,
                logger: logger
            )
        case .voiceMemos(let recordingsDir, let sessionGap):
            return try SourcePlanner.voiceMemoPlans(
                recordingsDir: recordingsDir,
                sessionGap: sessionGap,
                outputPrefix: options.outputPrefix,
                logger: logger
            )
        }
    }

    private func estimatedAudioDurationSeconds(for plan: PipelineSessionPlan) -> Double? {
        guard let recordings = plan.sourceMetadata?.voiceMemos?.recordings else { return nil }
        let durations = recordings.compactMap(\.durationSeconds).filter { $0 > 0 }
        guard !durations.isEmpty else { return nil }
        let paddingSeconds = Double(max(0, recordings.count - 1) * interClipPaddingSamples) / Double(WhisperKit.sampleRate)
        return durations.reduce(0, +) + paddingSeconds
    }

    private func validateSharedUsage() throws {
        let formats = options.resolvedFormats
        if formats.isEmpty {
            throw TranscribeError(message: "--format must include at least one of: txt, json, srt, vtt, md, tsv, all.", exitCode: .invalidUsage)
        }
        for f in formats where !validOutputFormats.contains(f) {
            throw TranscribeError(message: "Unsupported format '\(f)'. Supported: txt, json, srt, vtt, md, tsv, all.", exitCode: .invalidUsage)
        }

        let strategy = options.speakerMerge.lowercased()
        if strategy != "subsegment" && strategy != "segment" {
            throw TranscribeError(message: "--speaker-merge must be 'subsegment' or 'segment'.", exitCode: .invalidUsage)
        }

        if !options.speakersEnabled && (options.minSpeakers != nil || options.maxSpeakers != nil) {
            throw TranscribeError(message: "--speakers-min and --speakers-max are only valid when speaker labels are enabled.", exitCode: .invalidUsage)
        }
        if let min = options.minSpeakers, min <= 0 {
            throw TranscribeError(message: "--speakers-min must be greater than 0.", exitCode: .invalidUsage)
        }
        if let max = options.maxSpeakers, max <= 0 {
            throw TranscribeError(message: "--speakers-max must be greater than 0.", exitCode: .invalidUsage)
        }
        if let min = options.minSpeakers, let max = options.maxSpeakers, min > max {
            throw TranscribeError(message: "--speakers-min (\(min)) must be less than or equal to --speakers-max (\(max)).", exitCode: .invalidUsage)
        }

        if options.markImported && options.redo {
            throw TranscribeError(message: "--mark-imported cannot be combined with --redo.", exitCode: .invalidUsage)
        }
        if options.markImported && options.stateless {
            throw TranscribeError(message: "--mark-imported cannot be combined with --stateless.", exitCode: .invalidUsage)
        }

        if options.maxAudioMB < 0 {
            throw TranscribeError(message: "--max-audio-mb must be >= 0 (use 0 to disable the hard cap).", exitCode: .invalidUsage)
        }

        if case .directory(_, let directoryOptions) = request, directoryOptions.sessionGap < 0 {
            throw TranscribeError(message: "--session-gap must be >= 0 (use 0 to produce one transcript per recording).", exitCode: .invalidUsage)
        }
        if case .voiceMemos(_, let sessionGap) = request, sessionGap < 0 {
            throw TranscribeError(message: "--session-gap must be >= 0 (use 0 to produce one transcript per recording).", exitCode: .invalidUsage)
        }
    }

    private func processingDecision(
        plan: PipelineSessionPlan,
        fingerprint: SourceFingerprint,
        settings: ProcessingSettingsSignature,
        outputPaths: [String]
    ) throws -> ProcessingDecision {
        if options.stateless {
            return ProcessingDecision(action: .process, reason: .firstRun)
        }
        if options.redo {
            return ProcessingDecision(action: .process, reason: .redo)
        }
        let imported = try ProcessingStore.importedBaselineDecision(sourceID: plan.sourceID, fingerprint: fingerprint)
        if imported.shouldSkip {
            return imported
        }
        let completed = try ProcessingStore.completionDecision(
            sourceKind: plan.sourceKind,
            sourceID: plan.sourceID,
            fingerprint: fingerprint,
            settings: settings,
            outputPaths: outputPaths
        )
        if completed.shouldSkip {
            return completed
        }
        // Path-agnostic content match: catch the same audio under a new path
        // (file moved between directories) or extracted from a prior dir/voice
        // memos session into a single-file run.
        let content = try ProcessingStore.contentDecision(fingerprint: fingerprint, settings: settings)
        if content.shouldSkip {
            return content
        }
        if imported.reason != .firstRun {
            return imported
        }
        if completed.reason != .firstRun {
            return completed
        }
        return content
    }

    private func resolvedModelSelection() -> (model: String, source: String) {
        let chosen = options.model
        let source: String
        switch options.modelSource {
        case .cli, .userFile:
            source = options.modelSource == .cli ? "cli" : "config"
        case .builtin:
            source = "builtin"
        }
        return (chosen, source)
    }

    private func emitModelSelection(model: String, source: String, reporter: TranscribeEventReporter?) {
        reporter?.info(
            "phase_done",
            fields: [
                TranscribeEventField("phase", .string("model_selection")),
                TranscribeEventField("model", .string(model)),
                TranscribeEventField("model_source", .string(source)),
            ],
            message: source == "builtin" ? "model auto-selected" : "model selected"
        )
    }

    private func markPlannedInputsImported(workItems: [PipelineWorkItem], reporter: TranscribeEventReporter?) throws {
        var marked = 0
        for item in workItems {
            let plan = item.plan
            // Tag Voice Memos imports with their own baseline kind so the
            // history command (and any future tooling) can tell them apart
            // from generic file/dir imports without inspecting metadata.
            let baselineKind: ProcessingSourceKind = plan.sourceKind == .voiceMemos
                ? .voiceMemosBaseline
                : .importedBaseline
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: item.historyReason,
                source_kind: baselineKind,
                source_id: plan.sourceID,
                source_fingerprint: item.fingerprint,
                settings_signature: nil,
                output_dir: nil,
                basename: plan.basename,
                output_paths: [],
                audio_duration_s: nil,
                warning_count: 0,
                recording_title: plan.sourceMetadata?.recordingTitle,
                recorded_at: plan.sourceMetadata?.recordedAt,
                voice_memos_unique_id: plan.sourceMetadata?.voiceMemosUniqueID,
                voice_memos_path: plan.sourceMetadata?.voiceMemosPath
            ))
            marked += 1
            reporter?.info(
                "session_done",
                fields: sessionFields(
                    item: item,
                    outputDir: nil,
                    extra: [TranscribeEventField("history_reason", .string(item.historyReason.rawValue))]
                ),
                message: "input marked imported"
            )
        }
        reporter?.info(
            "phase_done",
            fields: [
                TranscribeEventField("phase", .string("mark_imported")),
                TranscribeEventField("marked", .int(marked)),
            ],
            message: "inputs marked imported"
        )
    }

    private func appendSkipRecords(workItems: [PipelineWorkItem], settings: ProcessingSettingsSignature?) throws {
        guard !options.stateless else { return }
        for item in workItems where item.recordsSkipHistory {
            let plan = item.plan
            let outputDir = item.outputPaths.isEmpty ? nil : resolvedOutputDir(options.outputDir)
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: item.historyReason,
                source_kind: plan.sourceKind,
                source_id: plan.sourceID,
                source_fingerprint: item.fingerprint,
                settings_signature: settings,
                output_dir: outputDir,
                basename: plan.basename,
                output_paths: item.outputPaths,
                audio_duration_s: nil,
                warning_count: 0,
                recording_title: plan.sourceMetadata?.recordingTitle,
                recorded_at: plan.sourceMetadata?.recordedAt,
                voice_memos_unique_id: plan.sourceMetadata?.voiceMemosUniqueID,
                voice_memos_path: plan.sourceMetadata?.voiceMemosPath
            ))
        }
    }

    private func emitSkippedSessions(_ items: [PipelineWorkItem], reporter: TranscribeEventReporter?) {
        for item in items {
            reporter?.debug(
                "session_skipped",
                fields: sessionFields(
                    item: item,
                    outputDir: item.outputPaths.isEmpty ? nil : resolvedOutputDir(options.outputDir),
                    extra: [TranscribeEventField("history_reason", .string(item.historyReason.rawValue))]
                ),
                message: "session skipped"
            )
        }
    }

    private func emitProcessingPhaseEvents(
        phases: PhaseTimings,
        item: PipelineWorkItem,
        outputDir: String,
        reporter: TranscribeEventReporter?
    ) {
        let encodingMs = phases.whisperAudioProcessingMs
            + phases.whisperLogmelsMs
            + phases.whisperEncodingMs
        emitPhaseDone(
            "encoding",
            milliseconds: encodingMs,
            item: item,
            outputDir: outputDir,
            reporter: reporter,
            message: "audio encoded"
        )
        emitPhaseDone(
            "transcription",
            milliseconds: phases.whisperDecodingLoopMs > 0 ? phases.whisperDecodingLoopMs : phases.transcribeOnlyMs,
            item: item,
            outputDir: outputDir,
            reporter: reporter,
            message: "transcription complete"
        )
        emitPhaseDone(
            "diarization",
            milliseconds: phases.speakerDiarizationMs,
            item: item,
            outputDir: outputDir,
            reporter: reporter,
            message: "diarization complete"
        )
    }

    private func emitPhaseDone(
        _ phase: String,
        milliseconds: Int64,
        item: PipelineWorkItem,
        outputDir: String,
        reporter: TranscribeEventReporter?,
        message: String
    ) {
        guard milliseconds > 0 else { return }
        reporter?.info(
            "phase_done",
            fields: sessionFields(
                item: item,
                outputDir: outputDir,
                extra: [
                    TranscribeEventField("phase", .string(phase)),
                    TranscribeEventField("elapsed_s", .double(Double(milliseconds) / 1000.0)),
                ]
            ),
            message: message
        )
    }

    private func sessionFields(
        item: PipelineWorkItem,
        outputDir: String?,
        extra: [TranscribeEventField] = []
    ) -> [TranscribeEventField] {
        let plan = item.plan
        let source = plan.sourceMetadata?.source ?? plan.sourceKind.rawValue
        let inputNames = plan.session.files.map { ($0 as NSString).lastPathComponent }
        let outputNames = item.outputPaths.map { ($0 as NSString).lastPathComponent }
        var fields: [TranscribeEventField] = [
            TranscribeEventField("source", .string(source)),
            TranscribeEventField("session", .string("\(item.sessionIndex + 1)/\(max(item.sessionTotal, 1))")),
            TranscribeEventField("input", .strings(inputNames)),
            TranscribeEventField("output_basename", .string(plan.basename)),
            TranscribeEventField("outputs", .strings(outputNames)),
        ]
        if let outputDir {
            fields.append(TranscribeEventField("output_dir", .string(outputDir)))
        }
        fields.append(contentsOf: extra)
        return fields
    }

    private func progressContextLines(
        item: PipelineWorkItem,
        model: String,
        outputDir: String
    ) -> [String] {
        let inputNames = item.plan.session.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        let outputNames = item.outputPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return [
            "Session: \(item.sessionIndex + 1)/\(max(item.sessionTotal, 1))",
            "Input: \(inputNames)",
            "Output: \(item.plan.basename) (\(options.resolvedFormats.joined(separator: ","))) -> \(outputDir)"
                + (outputNames.isEmpty ? "" : " [\(outputNames)]"),
            "Model: \(model)",
        ]
    }

    private func emitDryRunMarkImported(workItems: [PipelineWorkItem], skippedItems: [PipelineWorkItem]) {
        let total = workItems.count + skippedItems.count
        var lines: [String] = [
            "Dry run: \(total) session\(total == 1 ? "" : "s") scanned; \(workItems.count) would be marked imported, \(skippedItems.count) already imported or completed."
        ]
        for item in workItems {
            lines.append(dryRunLine(status: "mark-imported", item: item))
        }
        FileHandle.standardOutput.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    private func emitDryRun(workItems: [PipelineWorkItem], skippedItems: [PipelineWorkItem]) {
        let total = workItems.count + skippedItems.count
        var lines: [String] = [
            "Dry run: \(total) session\(total == 1 ? "" : "s") scanned; \(workItems.count) would process, \(skippedItems.count) would skip."
        ]
        for item in workItems {
            lines.append(dryRunLine(status: "process", item: item))
        }
        FileHandle.standardOutput.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
    }

    private func dryRunLine(status: String, item: PipelineWorkItem) -> String {
        let source = item.plan.sourceMetadata?.source ?? item.plan.sourceKind.rawValue
        let files = item.plan.session.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ",")
        let outputs = item.outputPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ",")
        return "\(status)\t\(source)\t\(item.plan.basename)\tfiles=\(files)\toutputs=\(outputs)"
    }
}

func runAndExitOnError(_ body: () async throws -> Void) async {
    defer { TranscribeEventReporter.setCurrent(nil) }
    do {
        try await body()
    } catch let e as TranscribeError {
        if !TranscribeEventReporter.emitError(e.message, exitCode: e.exitCode.rawValue) {
            FileHandle.standardError.write((e.message + "\n").data(using: .utf8)!)
        }
        Darwin.exit(e.exitCode.rawValue)
    } catch let e as WhisperError {
        if !TranscribeEventReporter.emitError(e.localizedDescription, exitCode: ExitCode.modelFailure.rawValue) {
            FileHandle.standardError.write((e.localizedDescription + "\n").data(using: .utf8)!)
        }
        Darwin.exit(ExitCode.modelFailure.rawValue)
    } catch {
        if !TranscribeEventReporter.emitError(error.localizedDescription, exitCode: ExitCode.runtimeFailure.rawValue) {
            FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
        }
        Darwin.exit(ExitCode.runtimeFailure.rawValue)
    }
}
