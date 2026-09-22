import Foundation

/// 面向界面的失败原因。调用方只展示 `errorDescription`，不把系统错误直接抛到界面上。
enum PlayerError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case damagedFile(String)
    case fileMissing
    case noAudioTrack
    case waveformFailed(String)
    case subtitleParse(String)
    case network(String)
    case notAuthorized
    case authorizationDenied
    case rateLimited
    case dlinkExpired
    case missingCredentials
    case database(String)
    case featureUnavailable(String)
    case streamUnsupported(String)
    case remuxFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            let shown = ext.isEmpty ? "未知" : ext.uppercased()
            return "不支持的格式（\(shown)）。常见视频用 MP4、MOV、MKV、AVI、WebM，音频用 MP3、M4A、WAV、FLAC。"
        case .damagedFile(let name):
            return "无法读取「\(name)」，文件可能已损坏。"
        case .fileMissing:
            return "找不到文件，可能已被移动或删除。"
        case .noAudioTrack:
            return "这个文件没有音轨，无法显示波形。"
        case .waveformFailed(let reason):
            return "波形提取失败（\(reason)）。播放不受影响。"
        case .subtitleParse(let reason):
            return "字幕解析失败：\(reason)"
        case .network(let reason):
            return "网络异常：\(reason)"
        case .notAuthorized:
            return "百度网盘尚未授权，请扫码登录。本地文件播放不受影响。"
        case .authorizationDenied:
            return "授权被拒绝或已过期。请重新扫码，本地播放不受影响。"
        case .rateLimited:
            return "百度网盘正在限速。非会员大文件会比较慢，下载可暂停，之后会从断点继续。"
        case .dlinkExpired:
            return "下载地址已失效，正在重新获取。"
        case .missingCredentials:
            return "请先在设置中填写百度网盘开放平台的 App Key 和 Secret Key。它们只保存在钥匙串。"
        case .database(let reason):
            return "本地资料库出错：\(reason)"
        case .featureUnavailable(let reason):
            return reason
        case .streamUnsupported(let name):
            return "「\(name)」不能在线播放。可以先下载，下载完成后从缓存播放。"
        case .remuxFailed(let name):
            return "在线转换没有播出来：「\(name)」。请再点一次播放。"
        }
    }
}
