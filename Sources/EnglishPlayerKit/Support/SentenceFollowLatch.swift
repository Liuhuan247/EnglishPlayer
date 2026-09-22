import Foundation

/// 句列表的自动滚动让位于用户。手动滚动后先停在用户看的位置，
/// 停一会儿且没有点新的一句，才回到正在播放的那一行。
struct SentenceFollowLatch: Equatable {
    var following = true
    private(set) var resumeAt: Date?
    var delay: TimeInterval = 3.5

    mutating func userScrolled(at now: Date = Date()) {
        following = false
        resumeAt = now.addingTimeInterval(delay)
    }

    mutating func userChoseSentence() {
        following = true
        resumeAt = nil
    }

    mutating func resumeIfDue(at now: Date = Date()) -> Bool {
        guard let resumeAt, now >= resumeAt else { return false }
        following = true
        self.resumeAt = nil
        return true
    }
}
