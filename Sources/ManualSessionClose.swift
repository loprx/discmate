import Foundation
import DiscRecording

/// Immutable target captured when the user opens the confirmation sheet.
struct ManualSessionClose: Identifiable, Sendable {
    let id = UUID()
    let snapshot: SessionSnapshot
    let drivePath: String

    func checkTarget() throws {
        try snapshot.identity.validate()
        guard snapshot.incompleteSession,
              let drive = (DRDevice.devices() as? [DRDevice])?.first(where: { $0.ioRegistryEntryPath() == drivePath }),
              drive.isValid() else { throw DiscFailure("原光驱或未关闭的会话已变化，请重新识别。") }
        let status = drive.status() as NSDictionary
        guard (status[DRDeviceIsBusyKey] as? NSNumber)?.boolValue == false,
              status[DRDeviceMediaStateKey] as? String == DRDeviceMediaStateMediaPresent else {
            throw DiscFailure("光驱忙碌或盘片状态不明，请等待设备空闲后重新识别。")
        }
        var driveID: UInt64 = 0
        var bsd = [CChar](repeating: 0, count: 64)
        var media = DMMedia()
        try checkSystem(dm_registry_identity(drivePath, &driveID), "确认光驱")
        try checkSystem(dm_registry_media(drivePath, driveID, &bsd, bsd.count, &media), "确认目标 DVD+R")
        guard media.registryID == snapshot.identity.registryID else { throw DiscFailure("目标盘片已更换。") }
    }

    func run() throws -> (Int32, DiagnosticEvidence) {
        let reader = try DVDSessionReader(identity: snapshot.identity)
        defer { reader.close() }
        let descriptor = try reader.closeSessionDescriptor(matching: snapshot)
        reader.close()
        let target = snapshot.latest
        guard let session = UInt16(exactly: target.session), let track = UInt16(exactly: target.number),
              descriptor.count == 2048 else { throw DiscFailure("无法确认目标会话或数据轨。") }
        var raw = DMCloseResult()
        let rc = descriptor.withUnsafeBytes { sector in
            dm_close_dvd_session(drivePath, snapshot.identity.registryID, session, track, target.start,
                                 target.blocks, sector.bindMemory(to: UInt8.self).baseAddress, &raw)
        }
        return (rc, Self.evidence(raw, result: rc))
    }

    static func evidence(_ raw: DMCloseResult, result rc: Int32) -> DiagnosticEvidence {
        let close = DiagnosticSessionClose(lastOpcode: raw.opcode, attempted: raw.attempted != 0,
            exclusive: raw.exclusive != 0, serviceResponse: raw.serviceResponse, taskStatus: raw.taskStatus,
            commandResult: raw.ioStatus == 0 && raw.exclusive == 0 ? rc : raw.ioStatus,
            releaseResult: raw.exclusive == 0 ? nil : raw.releaseStatus)
        let sense = withUnsafeBytes(of: raw.sense) { DiagnosticSense.parse(Data($0)) }
        return DiagnosticEvidence(sense: sense, sessionClose: close)
    }
}
