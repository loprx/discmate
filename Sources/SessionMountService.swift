import Foundation
import DiskArbitration

// The Disk Arbitration daemon interprets -s as a snapshot request even for
// cd9660, so it cannot forward ISO session selection on macOS 26.6.1.
final class MountAuthorization: @unchecked Sendable {
    let helper: String
    private let token: UnsafeMutableRawPointer
    init(helper: String) throws {
        self.helper = helper
        var status: Int32 = 0
        guard let token = dm_authorize_mount(helper, &status) else {
            throw DiscFailure("只读挂载授权未完成（\(status)）；没有执行挂载。")
        }
        self.token = token
    }
    deinit { dm_release_authorization(token) }
    func mount(_ snapshot: SessionSnapshot) throws -> URL {
        var output = [CChar](repeating: 0, count: 8192)
        let status = dm_authorized_mount(token, helper, snapshot.identity.bsd,
            String(snapshot.identity.registryID), String(snapshot.latest.start), &output, output.count)
        let text = String(cString: output)
        guard status == 0 else { throw DiscFailure("启动只读挂载助手失败（\(status)）：\(text)") }
        guard let line = text.split(separator: "\n").last, line.hasPrefix("OK\t") else {
            throw DiscFailure("只读挂载助手未成功：\(text)")
        }
        let path = String(line.dropFirst(3))
        guard path.hasPrefix("/Volumes/DiscMate-Session-"), URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Volumes" else {
            throw DiscFailure("挂载助手返回了无效路径。")
        }
        try snapshot.identity.validate()
        try checkSystem(dm_mount_matches(path, snapshot.identity.bsd), "确认只读挂载来源")
        return URL(fileURLWithPath: path)
    }
}

private final class MountCallback {
    let continuation: CheckedContinuation<Void, Error>
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
}

@MainActor
final class SessionMountService {
    private let session: DASession
    init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw DiscFailure("无法连接系统磁盘管理服务。") }
        self.session = session
        DASessionSetDispatchQueue(session, .main)
    }
    deinit { DASessionSetDispatchQueue(session, nil) }
    private func disk(_ identity: MediaIdentity) throws -> DADisk {
        try identity.validate()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(identity.bsd)") else {
            throw DiscFailure("系统未找到这张光盘。")
        }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        guard (description?[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true else {
            throw DiscFailure("目标不是整张光盘介质。")
        }
        return disk
    }
    func currentMount(_ identity: MediaIdentity) throws -> URL? {
        let description = DADiskCopyDescription(try disk(identity)) as? [String: Any]
        return description?[kDADiskDescriptionVolumePathKey as String] as? URL
    }
    func unmount(_ snapshot: SessionSnapshot) async throws {
        let disk = try disk(snapshot.identity)
        let description = DADiskCopyDescription(disk) as? [String: Any]
        guard description?[kDADiskDescriptionVolumeKindKey as String] as? String == "cd9660" else {
            throw DiscFailure("系统没有将这张光盘识别为 ISO 文件系统。")
        }
        if description?[kDADiskDescriptionVolumePathKey as String] != nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let box = Unmanaged.passRetained(MountCallback(continuation)).toOpaque()
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), Self.callback, box)
            }
        }
        try snapshot.identity.validate()
    }
    // The callback owns its context until Disk Arbitration actually completes.
    // A UI warning timer must not free it or start another hardware operation.
    private nonisolated static let callback: DADiskMountCallback = { _, dissenter, context in
        guard let context else { return }
        let box = Unmanaged<MountCallback>.fromOpaque(context).takeRetainedValue()
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            let text = DADissenterGetStatusString(dissenter) as String? ?? "系统拒绝了挂载操作"
            box.continuation.resume(throwing: DiscFailure("磁盘管理服务：\(text)（\(status)）。没有强制卸载或重试。"))
        } else { box.continuation.resume() }
    }
}
