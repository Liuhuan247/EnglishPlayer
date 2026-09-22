import Foundation

enum PlaybackTickAction: Equatable {
    case follow(index: Int, fraction: Double)
    case seek(Double, Int)
    case ended
    case idle
}

/// 句边界状态机。时间回调只问它“接下来跳还是跟着走”，不直接操作播放器。
struct SentenceEngine {
    private(set) var sentences: [Sentence] = []
    private(set) var currentIndex: Int = 0
    var loopMode: LoopMode = .off
    var blind: Bool = false
    var abStart: Double?
    var abEnd: Double?

    var current: Sentence? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex]
    }

    mutating func load(_ sentences: [Sentence]) {
        self.sentences = sentences.sorted { $0.index < $1.index }
        currentIndex = 0
        abStart = nil
        abEnd = nil
    }

    mutating func select(index: Int) -> Sentence? {
        guard sentences.indices.contains(index) else { return nil }
        currentIndex = index
        return sentences[index]
    }

    mutating func previous() -> Sentence? {
        select(index: currentIndex - 1)
    }

    mutating func next() -> Sentence? {
        select(index: currentIndex + 1)
    }

    func containingIndex(at time: Double, offset: Double) -> Int? {
        sentences.firstIndex { sentence in
            let start = sentence.startTime + offset
            let end = sentence.endTime + offset
            return time >= start && time < end
        }
    }

    /// 句尾前约 30ms 触发回跳，配合 50ms 的时间回调，避免越过句边界后才回头。
    func action(at time: Double, offset: Double) -> PlaybackTickAction {
        if loopMode == .ab, let start = abStart, let end = abEnd, end > start {
            if time >= end - 0.03 {
                let index = containingIndex(at: start, offset: offset) ?? currentIndex
                return .seek(max(0, start), index)
            }
            if let index = containingIndex(at: time, offset: offset) {
                let sentence = sentences[index]
                let sentenceStart = sentence.startTime + offset
                let duration = max(0.001, sentence.endTime - sentence.startTime)
                let fraction = min(1, max(0, (time - sentenceStart) / duration))
                return .follow(index: index, fraction: fraction)
            }
            return .idle
        }
        if loopMode == .sentence, let sentence = current {
            let start = sentence.startTime + offset
            let end = sentence.endTime + offset
            if time >= start, time >= end - 0.03 {
                return .seek(max(0, start), currentIndex)
            }
        }
        if let index = containingIndex(at: time, offset: offset) {
            let sentence = sentences[index]
            let start = sentence.startTime + offset
            let duration = max(0.001, sentence.endTime - sentence.startTime)
            let fraction = min(1, max(0, (time - start) / duration))
            return .follow(index: index, fraction: fraction)
        }
        if let last = sentences.last, time >= last.endTime + offset - 0.03 {
            return .ended
        }
        return .idle
    }

    /// 依次为：记下 A、记下 B 并开始循环、关闭并清空。B 早于 A 时自动对调。
    mutating func cycleAB(at time: Double) -> String {
        if abStart == nil || (abStart != nil && abEnd != nil) {
            if abStart != nil && abEnd != nil {
                abStart = nil
                abEnd = nil
                loopMode = .off
                return "A-B 循环：关"
            }
            abStart = time
            abEnd = nil
            loopMode = .off
            return "A-B 循环：已设置起点 A"
        }
        var start = abStart ?? time
        var end = time
        if end < start {
            swap(&start, &end)
        }
        if end - start < 0.2 {
            end = start + 0.2
        }
        abStart = start
        abEnd = end
        loopMode = .ab
        return "A-B 循环：开"
    }
}
