import Foundation
import CoreFoundation

// These enums are the export boundary. Never add user-facing error strings,
// source paths, volume labels, serials, hashes or raw backend dictionaries here.
enum DiagnosticTaskKind: String, Codable, CaseIterable {
    case dataBurn, append, appendPreparation, audioBurn, imageBurn, videoBurn, erase, readback, openLatest, eject, deviceRefresh
}

enum DiagnosticMediaType: String, Codable {
    case unknown, cdR, cdRW, dvdPlusR, dvdPlusRW, dvdMinusR, dvdMinusRW, dvdRAM, bdR, bdRE
}

enum DiagnosticDriveModel: String, Codable {
    case unknown, lenovoUltraslimDVD = "Lenovo Ultraslim DVD", hlDtStGTB0N = "HL-DT-ST DVDRAM GTB0N"

    /// Exact matching only: unusual/user-supplied device names are not collected.
    static func knownModel(_ cachedName: String?) -> Self {
        guard let cachedName else { return .unknown }
        return Self(rawValue: cachedName) ?? .unknown
    }
}

enum DiagnosticEventKind: String, Codable {
    case started, preparing, waiting, writing, verifying, finishing
    case backendDone, backendFailed, backendCancelled
    case deviceUnavailable, deviceAvailable, recoveryRequired
    case ejectRequested, ejectCompleted, mediaReturnedDuringCompletion, mountRequested, mountCompleted
    case panelFinished, panelCreationFailed, backendObservationUnavailable, backendReleased, registryObserved, deviceStatusObserved
    case preflightIdentityRejected, preflightCapabilityRejected, preflightUnavailable
    case appendSourcesChecked, appendSourcesRevalidated, appendPreflightRejected
    case readbackDirectoryMatched
    case readbackStarted, readbackAddedStarted, readbackFullStarted, readbackAddedSourcesMatched, readbackAllReadableKnownSourcesMatched, readbackAllReadable, readbackFailed, failed, completed, cancelled
}

enum DiagnosticOutcome: String, Codable {
    case inProgress, completed, failed, cancelled, needsRecovery
}

enum DiagnosticBackendState: String, Codable, Sendable {
    case none, preparing, sessionOpen, trackOpen, trackWrite, trackClose, sessionClose, verifying, finishing, erasing, done, failed, unknown

    static func fromSystemState(_ state: String) -> Self {
        switch state {
        case "DRStatusStateNone": return .none
        case "DRStatusStatePreparing": return .preparing
        case "DRStatusStateSessionOpen": return .sessionOpen
        case "DRStatusStateTrackOpen": return .trackOpen
        case "DRStatusStateTrackWrite": return .trackWrite
        case "DRStatusStateTrackClose": return .trackClose
        case "DRStatusStateSessionClose": return .sessionClose
        case "DRStatusStateVerifying": return .verifying
        case "DRStatusStateFinishing": return .finishing
        case "DRStatusStateErasing": return .erasing
        case "DRStatusStateDone": return .done
        case "DRStatusStateFailed": return .failed
        default: return .unknown
        }
    }
}

struct DiagnosticDeviceEvidence: Codable, Equatable, Sendable {
    let busy: Bool?
    let trayOpen: Bool?
    let mediaAbsent: Bool?
    let identityConfirmed: Bool?
    let registryMediaPresent: Bool?

    init(busy: Bool? = nil, trayOpen: Bool? = nil, mediaAbsent: Bool? = nil,
         identityConfirmed: Bool? = nil, registryMediaPresent: Bool? = nil) {
        self.busy = busy; self.trayOpen = trayOpen; self.mediaAbsent = mediaAbsent
        self.identityConfirmed = identityConfirmed; self.registryMediaPresent = registryMediaPresent
    }
}

struct DiagnosticDiscEvidence: Codable, Equatable, Sendable {
    let latestSession: UInt16?
    let latestStartLBA: UInt32?
    let nextWritableLBA: UInt32?
    let freeBlocks: UInt32?
    let rootEntryCount: UInt32?
    let appendable: Bool?
    let imageBytes: UInt64?

    init(latestSession: UInt16? = nil, latestStartLBA: UInt32? = nil,
         nextWritableLBA: UInt32? = nil, freeBlocks: UInt32? = nil,
         rootEntryCount: UInt32? = nil, appendable: Bool? = nil, imageBytes: UInt64? = nil) {
        self.latestSession = latestSession; self.latestStartLBA = latestStartLBA
        self.nextWritableLBA = nextWritableLBA; self.freeBlocks = freeBlocks
        self.rootEntryCount = rootEntryCount; self.appendable = appendable; self.imageBytes = imageBytes
    }
}

/// Classification and counts only; source names and directory paths stay local.
enum DiagnosticAppendFailure: String, Codable, Sendable {
    case conflict, unsupportedSource, invalidName, sourceChanged, mediaChanged, capacity, invalidTree, unavailable, other
}

struct DiagnosticAppendEvidence: Codable, Equatable, Sendable {
    let failure: DiagnosticAppendFailure?
    let addedFiles: Int?
    let addedDirectories: Int?
    let preservedFiles: Int?
    let preservedDirectories: Int?
    let addedBytes: UInt64?
    let sessionAllowanceBytes: UInt64?
    var isValid: Bool {
        [addedFiles, addedDirectories, preservedFiles, preservedDirectories].allSatisfy {
            $0 == nil || (0...10000).contains($0!)
        } && (addedBytes == nil || addedBytes! < UInt64(UInt32.max)) &&
        (sessionAllowanceBytes == nil || sessionAllowanceBytes! <= 1024 * 1024 * 1024)
    }
}

enum DiagnosticRefreshSource: String, Codable, Sendable {
    case startup, manual, deviceNotification, taskCompleted, fileSelection, recovery
}

struct DiagnosticRefreshEvidence: Codable, Equatable, Sendable {
    let source: DiagnosticRefreshSource?
    let appeared: Int
    let disappeared: Int
    let status: Int
    let duplicate: Int
    let deferredByTask: Bool
    let deferredByBusy: Bool
    init(source: DiagnosticRefreshSource? = nil, appeared: Int = 0, disappeared: Int = 0,
         status: Int = 0, duplicate: Int = 0, deferredByTask: Bool = false,
         deferredByBusy: Bool = false) {
        self.source = source; self.appeared = appeared; self.disappeared = disappeared
        self.status = status; self.duplicate = duplicate
        self.deferredByTask = deferredByTask; self.deferredByBusy = deferredByBusy
    }
    var isValid: Bool { [appeared, disappeared, status, duplicate].allSatisfy { (0...100_000).contains($0) } }
}

/// A snapshot of the known Lenovo test drive's registry subtree. Counts are
/// task-local observations, not persistent device identifiers or proof of a
/// working optical command path. An absent probe is unknown, not zero.
struct DiagnosticOpticalRegistryEvidence: Codable, Equatable, Sendable {
    let discRecordingDevices: Int
    let lenovoUSBDevices: Int
    let opticalPeripherals: Int
    let dvdMedia: Int

    var isValid: Bool {
        [discRecordingDevices, lenovoUSBDevices, opticalPeripherals, dvdMedia]
            .allSatisfy { (0...1_024).contains($0) }
    }
}

struct DiagnosticSense: Codable, Equatable, Sendable {
    let responseCode: UInt8
    let key: UInt8
    let asc: UInt8
    let ascq: UInt8

    private init(responseCode: UInt8, key: UInt8, asc: UInt8, ascq: UInt8) {
        self.responseCode = responseCode; self.key = key; self.asc = asc; self.ascq = ascq
    }

    static func extract(backendError: Any?) -> Self? {
        guard let fields = backendError as? NSDictionary,
              let data = fields["DRErrorStatusSenseKey"] as? Data else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Self? {
        // Fixed format offsets follow Apple's SCSICmds_REQUEST_SENSE_Defs.h;
        // descriptor format puts key/ASC/ASCQ in bytes 1/2/3. No information,
        // command-specific fields, vendor data or descriptors are exported.
        guard data.count >= 8 else { return nil }
        let header = Array(data.prefix(14))
        let response = header[0] & 0x7F
        let additional = Int(header[7])
        guard data.count >= 8 + additional else { return nil }
        switch response {
        case 0x70, 0x71:
            guard header.count >= 14, additional >= 6 else { return nil }
            return Self(responseCode: response, key: header[2] & 0x0F, asc: header[12], ascq: header[13])
        case 0x72, 0x73:
            guard header[0] == response else { return nil }
            return Self(responseCode: response, key: header[1] & 0x0F, asc: header[2], ascq: header[3])
        default: return nil
        }
    }

    var isValid: Bool { (0x70...0x73).contains(responseCode) && key <= 0x0F }
}

struct DiagnosticEvidence: Codable, Equatable, Sendable {
    let backendState: DiagnosticBackendState?
    let requestedSpeedAutomatic: Bool?
    let verifyAfterWriteRequested: Bool?
    let verifyAfterWriteAccepted: Bool?
    let requestedSpeedKBps: Double?
    let actualSpeedKBps: Double?
    let sense: DiagnosticSense?
    let device: DiagnosticDeviceEvidence?
    let disc: DiagnosticDiscEvidence?
    let refresh: DiagnosticRefreshEvidence?
    let opticalRegistry: DiagnosticOpticalRegistryEvidence?
    let append: DiagnosticAppendEvidence?

    init(backendState: DiagnosticBackendState? = nil, requestedSpeedKBps: Double? = nil,
         actualSpeedKBps: Double? = nil, requestedSpeedAutomatic: Bool? = nil,
         verifyAfterWriteRequested: Bool? = nil, verifyAfterWriteAccepted: Bool? = nil,
         sense: DiagnosticSense? = nil,
         device: DiagnosticDeviceEvidence? = nil, disc: DiagnosticDiscEvidence? = nil,
         refresh: DiagnosticRefreshEvidence? = nil,
         opticalRegistry: DiagnosticOpticalRegistryEvidence? = nil,
         append: DiagnosticAppendEvidence? = nil) {
        self.backendState = backendState
        self.requestedSpeedAutomatic = requestedSpeedAutomatic
        self.verifyAfterWriteRequested = verifyAfterWriteRequested
        self.verifyAfterWriteAccepted = verifyAfterWriteAccepted
        // DiscRecording reports its maximum-speed sentinel as a number even
        // when the user selected automatic. Export the choice, not that token.
        self.requestedSpeedKBps = requestedSpeedAutomatic == true ? nil : Self.validSpeed(requestedSpeedKBps)
        self.actualSpeedKBps = Self.validSpeed(actualSpeedKBps)
        self.sense = sense?.isValid == true ? sense : nil
        self.device = device
        self.disc = disc
        self.refresh = refresh?.isValid == true ? refresh : nil
        self.opticalRegistry = opticalRegistry?.isValid == true ? opticalRegistry : nil
        self.append = append?.isValid == true ? append : nil
    }

    private static func validSpeed(_ value: Double?) -> Double? {
        // Omit auto/max sentinels and nonsensical rates; the ceiling is far
        // beyond optical throughput and avoids exporting unbounded numbers.
        guard let value, value.isFinite, value > 0, value <= 1_000_000 else { return nil }
        return value
    }

    var isValid: Bool {
        (requestedSpeedKBps == nil || Self.validSpeed(requestedSpeedKBps) != nil) &&
        (actualSpeedKBps == nil || Self.validSpeed(actualSpeedKBps) != nil) &&
        (sense == nil || sense!.isValid) && (refresh == nil || refresh!.isValid) &&
        (opticalRegistry == nil || opticalRegistry!.isValid) && (append == nil || append!.isValid)
    }

    fileprivate func includingSense(_ parsed: DiagnosticSense?) -> Self {
        Self(backendState: backendState, requestedSpeedKBps: requestedSpeedKBps,
             actualSpeedKBps: actualSpeedKBps, requestedSpeedAutomatic: requestedSpeedAutomatic,
             verifyAfterWriteRequested: verifyAfterWriteRequested,
             verifyAfterWriteAccepted: verifyAfterWriteAccepted,
             sense: sense ?? parsed, device: device, disc: disc, refresh: refresh,
             opticalRegistry: opticalRegistry, append: append)
    }
}

struct DiagnosticErrorCode: Codable, Equatable {
    enum Source: String, Codable, Sendable { case cocoa, posix, osStatus, discRecording, process, other }
    let source: Source
    let code: Int64

    static func extract(error: NSError?, backendError: Any?) -> [Self] {
        var result: [Self] = []
        if let error {
            let source: Source
            switch error.domain {
            case NSCocoaErrorDomain: source = .cocoa
            case NSPOSIXErrorDomain: source = .posix
            case NSOSStatusErrorDomain: source = .osStatus
            case "DiscMate.Process": source = .process
            default: source = .other
            }
            result.append(Self(source: source, code: Int64(error.code)))
        }
        // Only the documented numeric field is consumed. Never parse arbitrary
        // message text (which can embed a filename, URL, token or credentials).
        if let fields = backendError as? NSDictionary,
           let value = fields["DRErrorStatusErrorKey"], let code = numericCode(value) {
            let entry = Self(source: .discRecording, code: code)
            if !result.contains(entry) { result.append(entry) }
        }
        return result
    }

    private static func numericCode(_ value: Any) -> Int64? {
        // Numbers and numeric strings must fit in Int64; reject suffixes,
        // whitespace, non-ASCII digits and booleans rather than truncating them.
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            text = value.stringValue
        } else { return nil }
        guard text.count <= 21 else { return nil }
        if text.range(of: "^0[xX][0-9A-Fa-f]+$", options: .regularExpression) != nil {
            return Int64(text.dropFirst(2), radix: 16)
        }
        guard text.range(of: "^-?[0-9]+$", options: .regularExpression) != nil else { return nil }
        return Int64(text)
    }
}

struct DiagnosticEvent: Codable {
    let at: Date
    let elapsedSeconds: Double
    let kind: DiagnosticEventKind
    let progressPercent: Int?
    let errorCodes: [DiagnosticErrorCode]
    var evidence: DiagnosticEvidence? = nil
}

struct DiagnosticReport: Codable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let task: DiagnosticTaskKind
    let appVersion: String
    let appBuild: String
    let macOSVersion: String
    let startedAt: Date
    var updatedAt: Date
    let media: DiagnosticMediaType
    let driveModel: DiagnosticDriveModel
    let fileCount: Int?
    let totalBytes: UInt64?
    var outcome: DiagnosticOutcome
    var events: [DiagnosticEvent]
    var omittedEventCount: Int
    // Completion, device release and readback remain separate event types.
    // Each readback outcome states its scope; absence never implies verification.
}

enum DiagnosticExportError: Error { case taskUnavailable, storageUnavailable }

/// All mutable state and filesystem access are confined to queue. Public
/// recording calls enqueue bounded, sanitized values and never wait for disk I/O.
final class DiagnosticReportStore: @unchecked Sendable {
    static let shared = DiagnosticReportStore()
    static let maximumReports = 30
    static let maximumEvents = 256
    private let queue = DispatchQueue(label: "local.discmate.diagnostics", qos: .utility)
    private let directory: URL
    private let version: String
    private let build: String
    private let osVersion: String
    private var loaded = false
    private var storageFailed = false
    private var history: [DiagnosticReport] = []

    init(directory: URL? = nil, appVersion: String? = nil, appBuild: String? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscMate/Diagnostics", isDirectory: true)
        version = Self.numericVersion(appVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        build = Self.numericVersion(appBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    @discardableResult
    func startTask(kind: DiagnosticTaskKind, media: DiagnosticMediaType = .unknown,
                   driveModel: DiagnosticDriveModel = .unknown, fileCount: Int? = nil,
                   totalBytes: UInt64? = nil) -> UUID {
        let id = UUID(), now = Date()
        queue.async {
            self.load()
            let event = DiagnosticEvent(at: now, elapsedSeconds: 0, kind: .started, progressPercent: nil, errorCodes: [])
            self.history.insert(DiagnosticReport(schemaVersion: 1, id: id, task: kind,
                appVersion: self.version, appBuild: self.build, macOSVersion: self.osVersion,
                startedAt: now, updatedAt: now, media: media, driveModel: driveModel,
                fileCount: fileCount.flatMap { $0 >= 0 ? $0 : nil }, totalBytes: totalBytes,
                outcome: .inProgress, events: [event], omittedEventCount: 0), at: 0)
            self.history = Array(self.history.prefix(Self.maximumReports))
            self.persist()
        }
        return id
    }

    func record(taskID: UUID, event: DiagnosticEventKind, progress: Double? = nil,
                error: NSError? = nil, backendError: Any? = nil, evidence: DiagnosticEvidence? = nil) {
        // Extract before crossing queues; never retain an arbitrary mutable
        // NSError/userInfo or backend dictionary in the archive worker.
        let codes = DiagnosticErrorCode.extract(error: error, backendError: backendError)
        let sense = DiagnosticSense.extract(backendError: backendError)
        let safeEvidence = evidence?.includingSense(sense) ?? sense.map { DiagnosticEvidence(sense: $0) }
        let percent = progress.flatMap { $0.isFinite && (0...1).contains($0) ? Int(($0 * 100).rounded()) : nil }
        let now = Date()
        queue.async {
            self.load()
            guard let index = self.history.firstIndex(where: { $0.id == taskID }) else { return }
            let last = self.history[index].events.last
            if last?.kind == event && last?.progressPercent == percent && last?.errorCodes == codes && last?.evidence == safeEvidence { return }
            let started = self.history[index].startedAt
            self.history[index].events.append(DiagnosticEvent(at: now,
                elapsedSeconds: max(0, now.timeIntervalSince(started)), kind: event,
                progressPercent: percent, errorCodes: codes, evidence: safeEvidence))
            self.history[index].updatedAt = now
            while self.history[index].events.count > Self.maximumEvents {
                let removable = Self.eventToOmit(self.history[index].events)
                self.history[index].events.remove(at: removable)
                self.history[index].omittedEventCount += 1
            }
            self.persist()
        }
    }

    private static func eventToOmit(_ events: [DiagnosticEvent]) -> Int {
        // Prefer an interior progress sample from a continuous phase. The
        // preceding and following samples survive, so phase entry, its last
        // progress, and timing boundaries are retained even when rates change
        // on every notification. Error/sense/device evidence is never a routine
        // sample, even when its event also carries a progress percentage.
        func routine(_ event: DiagnosticEvent) -> Bool {
            guard event.errorCodes.isEmpty, event.evidence?.sense == nil,
                  event.evidence?.device == nil, event.evidence?.disc == nil else { return false }
            switch event.kind {
            case .preparing, .waiting, .writing, .verifying, .finishing: return true
            default: return false
            }
        }
        func samePhase(_ a: DiagnosticEvent, _ b: DiagnosticEvent) -> Bool {
            a.kind == b.kind && a.evidence?.backendState == b.evidence?.backendState
        }
        let interior = events.indices.dropFirst().dropLast()
        if let index = interior.first(where: {
            routine(events[$0]) && events[$0].progressPercent != nil &&
            samePhase(events[$0 - 1], events[$0]) && samePhase(events[$0], events[$0 + 1])
        }) { return index }
        // A finite archive cannot retain unlimited distinct phases or failures.
        // Once redundant progress is exhausted, sacrifice ordinary phase
        // observations before terminal/error/device evidence. If every entry
        // is important, preserve task start and newest event, omit the oldest
        // remaining one and expose the loss through omittedEventCount.
        if let index = interior.first(where: { routine(events[$0]) }) { return index }
        return 1
    }

    func finish(taskID: UUID, outcome: DiagnosticOutcome) {
        queue.async {
            self.load()
            guard let index = self.history.firstIndex(where: { $0.id == taskID }) else { return }
            self.history[index].outcome = outcome
            self.history[index].updatedAt = Date()
            self.persist()
        }
    }

    func reports() async -> [DiagnosticReport] {
        await withCheckedContinuation { continuation in
            queue.async { self.load(); continuation.resume(returning: self.history) }
        }
    }

    func persistenceIssue() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { self.load(); continuation.resume(returning: self.storageFailed) }
        }
    }

    func exportData(taskID: UUID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.load()
                guard let report = self.history.first(where: { $0.id == taskID }) else {
                    continuation.resume(throwing: DiagnosticExportError.taskUnavailable); return
                }
                do { continuation.resume(returning: try Self.encoder().encode(report)) }
                catch { continuation.resume(throwing: DiagnosticExportError.storageUnavailable) }
            }
        }
    }

    private static func numericVersion(_ raw: String?) -> String {
        guard let raw, raw.count <= 40,
              raw.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil else { return "unknown" }
        return raw
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func load() {
        guard !loaded else { return }; loaded = true
        let archive = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 8_000_000 else { throw DiagnosticExportError.storageUnavailable }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([DiagnosticReport].self, from: Data(contentsOf: archive))
            // Validate even our own archive before exporting: replacement or
            // old future fields must not turn persisted strings into raw logs.
            guard decoded.count <= Self.maximumReports, decoded.allSatisfy({ report in
                report.schemaVersion == 1 && report.events.count <= Self.maximumEvents && report.omittedEventCount >= 0 &&
                (report.fileCount == nil || report.fileCount! >= 0) &&
                [report.appVersion, report.appBuild, report.macOSVersion].allSatisfy { $0 == "unknown" || Self.numericVersion($0) == $0 } &&
                report.events.allSatisfy { $0.elapsedSeconds.isFinite && $0.elapsedSeconds >= 0 && ($0.progressPercent == nil || (0...100).contains($0.progressPercent!)) && $0.errorCodes.count <= 2 && ($0.evidence?.isValid ?? true) }
            }) else { throw DiagnosticExportError.storageUnavailable }
            history = decoded
        } catch { storageFailed = true }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("history.json")
            try Self.encoder().encode(history).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { storageFailed = true }
    }
}
