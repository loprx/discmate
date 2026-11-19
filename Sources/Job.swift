enum Job: String, CaseIterable, Identifiable {
    case data = "数据光盘"
    case audio = "音频 CD"
    case image = "刻录镜像"
    case video = "VIDEO_TS"
    case erase = "擦除光盘"
    case info = "光盘信息"

    var id: String { rawValue }

    var shortcutKey: Character {
        switch self {
        case .data: "1"
        case .audio: "2"
        case .image: "3"
        case .video: "4"
        case .erase: "5"
        case .info: "6"
        }
    }
}

