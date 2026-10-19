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
    /// A、B 都是句子下标。时间随字幕偏移现算，避免拖进度条时落在半句上。
    private(set) var abFrom: Int?
    private(set) var abTo: Int?

    var current: Sentence? {
        guard sentences.indices.contains(currentIndex) else { return nil }
        return sentences[currentIndex]
    }

    mutating func load(_ sentences: [Sentence]) {
        self.sentences = sentences.sorted { $0.index < $1.index }
        currentIndex = 0
        abFrom = nil
        abTo = nil
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
        if loopMode == .ab, let bounds = sentenceBounds(offset: offset), bounds.end > bounds.start {
            if time >= bounds.end - 0.03 {
                let index = containingIndex(at: bounds.start, offset: offset) ?? abFrom ?? currentIndex
                return .seek(max(0, bounds.start), index)
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

    /// 按当前所在句设置 A、B。第一次记下整句起点，第二次把当前句当作结束句并开始循环，第三次关闭。
    mutating func cycleAB(at time: Double, offset: Double) -> String {
        guard let index = sentenceIndex(at: time, offset: offset) else {
            return "需要字幕才能按句设置 A-B"
        }
        if abFrom != nil, abTo != nil {
            abFrom = nil
            abTo = nil
            loopMode = .off
            return "A-B 循环：关"
        }
        if abFrom == nil {
            abFrom = index
            abTo = nil
            loopMode = .off
            return "A-B 循环：第 \(sentences[index].displayIndex) 句为起点"
        }
        var from = abFrom ?? index
        var to = index
        if to < from {
            swap(&from, &to)
        }
        abFrom = from
        abTo = to
        loopMode = .ab
        if from == to {
            return "A-B 循环：第 \(sentences[from].displayIndex) 句"
        }
        return "A-B 循环：第 \(sentences[from].displayIndex)–\(sentences[to].displayIndex) 句"
    }

    mutating func clearLoopBounds() {
        abFrom = nil
        abTo = nil
    }

    /// 拖动进度条时，A 吸到那一句的开头，B 吸到那一句的结尾。
    mutating func moveSentenceBound(isStart: Bool, at time: Double, offset: Double) -> Bool {
        guard let index = sentenceIndex(at: time, offset: offset) else { return false }
        if isStart {
            abFrom = index
        } else {
            if abFrom == nil { abFrom = index }
            abTo = index
        }
        if let from = abFrom, let to = abTo, to < from {
            abFrom = to
            abTo = from
        }
        if abFrom != nil, abTo != nil {
            loopMode = .ab
        }
        return true
    }

    func loopBounds(offset: Double) -> (start: Double?, end: Double?) {
        guard let bounds = sentenceBounds(offset: offset) else {
            guard let from = abFrom, sentences.indices.contains(from) else { return (nil, nil) }
            return (sentences[from].startTime + offset, nil)
        }
        return (bounds.start, bounds.end)
    }

    private func sentenceBounds(offset: Double) -> (start: Double, end: Double)? {
        guard let from = abFrom, let to = abTo,
              sentences.indices.contains(from), sentences.indices.contains(to) else { return nil }
        return (sentences[from].startTime + offset, sentences[to].endTime + offset)
    }

    /// 点在句与句的空隙里时，归到前面那一句；还没到第一句就用第一句。
    private func sentenceIndex(at time: Double, offset: Double) -> Int? {
        guard !sentences.isEmpty else { return nil }
        if let exact = containingIndex(at: time, offset: offset) { return exact }
        let adjusted = time - offset
        if adjusted <= sentences[0].startTime { return 0 }
        if let next = sentences.firstIndex(where: { adjusted < $0.startTime }) {
            return max(0, next - 1)
        }
        return sentences.count - 1
    }
}
