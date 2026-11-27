import Foundation
import DiscRecording
import CryptoKit

enum ReservedAppend {
    struct Completion {
        let result: Int32
        let evidence: DiagnosticEvidence
        let driveID: UInt64
        let speed: UInt16
    }

    static func write(snapshot: SessionSnapshot, prepared: PreparedIncrementalISO, path: String,
                      speed: BurnSpeedSelection) throws -> Completion {
        try ManualSessionClose(snapshot: snapshot, drivePath: path).checkTarget()
        guard let reserved = snapshot.reservedTrack, let tail = snapshot.tracks.last,
              let device = (DRDevice.devices() as? [DRDevice])?.first(where: { $0.ioRegistryEntryPath() == path }) else {
            throw DiscFailure("预留轨道或光驱已变化。")
        }
        let speeds = BurnSpeedOptions.values(fromStatus: device.status() as NSDictionary)
        let chosen = try speed.requestedSpeed(supported: speeds)
        guard let rate = chosen.map(Double.init) ?? speeds.max(), let kbps = UInt16(exactly: rate.rounded()),
              kbps > 0 else { throw BurnSpeedUnavailable() }
        var driveID: UInt64 = 0
        try checkSystem(dm_registry_identity(path, &driveID), "确认原光驱")
        try prepared.validateSourcesUnchanged()
        let image = try Data(contentsOf: prepared.image, options: .mappedIfSafe)
        guard image.count == prepared.imageBytes, SHA256.hash(data: image).map({String(format: "%02x", $0)}).joined() == prepared.imageSHA256,
              prepared.proof.expectedStart == reserved.start else { throw DiscFailure("待写镜像或起点发生变化。") }
        try IncrementalISO.validateTarget(snapshot, imageBytes: prepared.imageBytes)
        let reader = try DVDSessionReader(identity: snapshot.identity)
        defer { reader.close() }
        let descriptor = try reader.closeSessionDescriptor(matching: snapshot)
        reader.close()
        let previous = snapshot.latest
        let target = DMReservation(session: UInt16(reserved.session), track: UInt16(reserved.number),
            previousTrack: UInt16(previous.number), speedKBps: kbps, start: reserved.start, blocks: reserved.blocks,
            tailBlocks: tail.blocks, previousStart: previous.start, previousBlocks: previous.blocks)
        var raw = DMCloseResult()
        let rc = descriptor.withUnsafeBytes { sector in
            image.withUnsafeBytes { payload in
                dm_resume_reserved(path, snapshot.identity.registryID, target, sector.bindMemory(to: UInt8.self).baseAddress,
                    payload.bindMemory(to: UInt8.self).baseAddress, payload.count, &raw)
            }
        }
        return Completion(result: rc, evidence: ManualSessionClose.evidence(raw, result: rc),
                          driveID: driveID, speed: kbps)
    }

    // Exclusive release replaces the registry media object on macOS. Wait for
    // that same drive, then validate the new session against the persisted proof.
    static func readback(path: String, driveID: UInt64, proof: AppendProof) async throws -> SessionSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        repeat {
            var bsd = [CChar](repeating: 0, count: 64)
            var raw = DMMedia()
            let rc = dm_registry_media(path, driveID, &bsd, bsd.count, &raw)
            if rc == 0 {
                let identity = try MediaIdentity.current(String(cString: bsd))
                guard identity.registryID == raw.registryID else { throw LegacyPreflightFailure.changedMedium }
                let reader = try DVDSessionReader(identity: identity, timeBudget: 1800)
                defer { reader.close() }
                let fresh = try reader.scan()
                guard !fresh.incompleteSession else { throw DiscFailure("写后会话仍未关闭。") }
                try proof.validateDirectory(fresh)
                let files = try reader.verifyRecorded(fresh, paths: Set(proof.files.map(\.path)))
                try proof.validate(files, session: fresh.latest.session, start: fresh.latest.start, addedOnly: true)
                return fresh
            }
            guard rc == ENOENT || rc == EAGAIN else { try checkSystem(rc, "等待原光驱重新识别盘片"); break }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw DiscFailure("设备尚未重新识别介质。合仓后可载入本次源清单，只读核对新增文件。")
    }
}
