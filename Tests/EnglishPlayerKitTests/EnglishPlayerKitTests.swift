import AppKit
import XCTest
@testable import EnglishPlayerKit

final class SubtitleEngineTests: XCTestCase {
    func testSRTTimingAndBilingualLines() throws {
        let text = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello there
        你好

        2
        00:00:05,500 --> 00:00:08,000
        See you
        """
        let sentences = try SubtitleEngine.parse(text: text, format: .srt)
        XCTAssertEqual(sentences.count, 2)
        XCTAssertEqual(sentences[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(sentences[0].endTime, 4, accuracy: 0.001)
        XCTAssertEqual(sentences[0].textEn, "Hello there")
        XCTAssertEqual(sentences[0].textZh, "你好")
        XCTAssertEqual(sentences[1].textEn, "See you")
    }

    func testLRCUsesNextLineAsEnd() throws {
        let text = """
        [00:01.00]Hello
        [00:03.50]I'll be there
        """
        let sentences = try SubtitleEngine.parse(text: text, format: .lrc)
        XCTAssertEqual(sentences[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(sentences[0].endTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(sentences[1].textEn, "I'll be there")
        XCTAssertGreaterThan(sentences[1].endTime, 3.5)
    }

    func testPairChineseSidecarByTime() {
        let english = [
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 1, endTime: 3, textEn: "Hello", textZh: ""),
            Sentence(id: "b", mediaID: "m", index: 1, startTime: 4, endTime: 6, textEn: "World", textZh: "")
        ]
        let chinese = [
            Sentence(id: "c", mediaID: "m", index: 0, startTime: 1.1, endTime: 2.8, textEn: "", textZh: "你好"),
            Sentence(id: "d", mediaID: "m", index: 1, startTime: 4.2, endTime: 5.5, textEn: "", textZh: "世界")
        ]
        let paired = SubtitleEngine.pair(primary: english, secondary: chinese)
        XCTAssertEqual(paired[0].textZh, "你好")
        XCTAssertEqual(paired[1].textZh, "世界")
        XCTAssertEqual(paired[0].textEn, "Hello")
    }

    func testOffsetShiftsEveryCue() {
        let original = [
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 2, endTime: 4, textEn: "Hi", textZh: "")
        ]
        let shifted = SubtitleEngine.applying(offset: 0.12, to: original)
        XCTAssertEqual(shifted[0].startTime, 2.12, accuracy: 0.0001)
        XCTAssertEqual(original[0].startTime, 2, accuracy: 0.0001)
    }

    func testMissingSubtitleDoesNotThrow() {
        let result = SubtitleEngine.load(mediaPath: "/tmp/does-not-exist-\(UUID().uuidString).mp4", explicitRefs: [])
        XCTAssertTrue(result.sentences.isEmpty)
        XCTAssertNotNil(result.warning)
    }

    func testBrokenSubtitleIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("clip.mp4")
        try Data().write(to: media)
        try Data("not a subtitle".utf8).write(to: dir.appendingPathComponent("clip.srt"))
        let result = SubtitleEngine.load(mediaPath: media.path, explicitRefs: [])
        XCTAssertTrue(result.sentences.isEmpty)
        XCTAssertNotNil(result.warning)
    }
}

final class SentenceEngineTests: XCTestCase {
    func testSentenceLoopSeeksToStart() {
        var engine = SentenceEngine()
        engine.load([
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 10, endTime: 12, textEn: "One", textZh: ""),
            Sentence(id: "b", mediaID: "m", index: 1, startTime: 12, endTime: 15, textEn: "Two", textZh: "")
        ])
        engine.loopMode = .sentence
        let action = engine.action(at: 11.98, offset: 0)
        XCTAssertEqual(action, .seek(10, 0))
    }

    func testABLoopSeeksToA() {
        var engine = SentenceEngine()
        engine.load([
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 0, endTime: 20, textEn: "Long", textZh: "")
        ])
        XCTAssertEqual(engine.cycleAB(at: 4), "A-B 循环：已设置起点 A")
        XCTAssertEqual(engine.cycleAB(at: 9), "A-B 循环：开")
        let action = engine.action(at: 8.99, offset: 0)
        XCTAssertEqual(action, .seek(4, 0))
    }

    func testFollowsCurrentSentenceAndHighlightsFraction() {
        var engine = SentenceEngine()
        engine.load([
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 0, endTime: 10, textEn: "One", textZh: "")
        ])
        let action = engine.action(at: 2.5, offset: 0)
        XCTAssertEqual(action, .follow(index: 0, fraction: 0.25))
        XCTAssertNotNil(engine.select(index: 0))
        XCTAssertNil(engine.previous())
        XCTAssertNil(engine.next())
    }

    func testPreviousAndNext() {
        var engine = SentenceEngine()
        engine.load([
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 0, endTime: 1, textEn: "A", textZh: ""),
            Sentence(id: "b", mediaID: "m", index: 1, startTime: 1, endTime: 2, textEn: "B", textZh: "")
        ])
        XCTAssertEqual(engine.next()?.textEn, "B")
        XCTAssertEqual(engine.previous()?.textEn, "A")
    }

    func testBlindFlagDoesNotChangeTiming() {
        var engine = SentenceEngine()
        engine.load([
            Sentence(id: "a", mediaID: "m", index: 0, startTime: 0, endTime: 4, textEn: "A", textZh: "")
        ])
        engine.blind = true
        XCTAssertEqual(engine.action(at: 1, offset: 0), .follow(index: 0, fraction: 0.25))
    }
}

final class PlaybackRateTests: XCTestCase {
    func testQuarterStepRange() {
        XCTAssertEqual(PlaybackRate.all, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(PlaybackRate.stepped(0.62), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackRate.stepped(0.7), 0.75, accuracy: 0.001)
        XCTAssertEqual(PlaybackRate.stepped(3), 2, accuracy: 0.001)
        XCTAssertEqual(PlaybackRate.stepped(0.1), 0.5, accuracy: 0.001)
        XCTAssertEqual(PlaybackRate.numberKeys.count, 5)
    }
}

final class DictionaryServiceTests: XCTestCase {
    func testApostropheAndHyphenSurvive() {
        XCTAssertEqual(WordToken.normalize("you're,"), "you're")
        XCTAssertEqual(WordToken.normalize("well-known"), "well-known")
        let url = DictionaryService.url(for: "you're")
        XCTAssertEqual(url?.scheme, "eudic")
        XCTAssertEqual(url?.host, "dict")
        let absolute = url?.absoluteString ?? ""
        XCTAssertTrue(absolute.contains("you"))
        XCTAssertTrue(absolute.contains("re"))
    }

    func testNotInstalledDoesNotCrash() {
        let service = DictionaryService(opener: { _ in false }, availability: { _ in false })
        XCTAssertEqual(service.lookup("available"), .notInstalled)
    }

    func testOpensNormalizedWord() {
        var opened: URL?
        let service = DictionaryService(
            opener: { opened = $0; return true },
            availability: { _ in true }
        )
        XCTAssertEqual(service.lookup("\"hello\""), .opened("hello"))
        XCTAssertEqual(opened?.host, "dict")
    }
}

@MainActor
final class LibraryServiceTests: XCTestCase {
    func testPlaylistReorderAndSettingsSurviveReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        let store = try SQLiteStore(path: url.path)
        let library = LibraryService(store: store)
        let first = library.importLocal(urls: [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mp3")])
        XCTAssertEqual(first.count, 2)
        library.movePlaylist(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(library.playlist.map(\.path), ["/tmp/b.mp3", "/tmp/a.mp4"])
        library.removeFromPlaylist(at: 0)
        XCTAssertEqual(library.playlist.count, 1)
        library.setDefaultRate(1.25)
        library.setSubtitleOffset(0.12)
        library.setCacheLimit(5 * 1024 * 1024 * 1024)
        library.remember(mediaID: library.playlist[0].id)
        library.savePlayback(mediaID: library.playlist[0].id, position: 42, rate: 1.25, loopMode: .sentence)

        let reopened = LibraryService(store: try SQLiteStore(path: url.path))
        XCTAssertEqual(reopened.settings.defaultRate, 1.25, accuracy: 0.001)
        XCTAssertEqual(reopened.settings.subtitleOffset, 0.12, accuracy: 0.001)
        XCTAssertEqual(reopened.settings.cacheLimitBytes, 5 * 1024 * 1024 * 1024)
        XCTAssertEqual(reopened.settings.lastMediaID, library.playlist[0].id)
        XCTAssertEqual(reopened.settings.appearance, .system)
        XCTAssertTrue(reopened.settings.waveformVisible)
        XCTAssertFalse(reopened.settings.statusBarVisible)
        library.setAppearance(.dark)
        library.setWaveformVisible(false)
        library.setStatusBarVisible(true)
        let themed = LibraryService(store: try SQLiteStore(path: url.path))
        XCTAssertEqual(themed.settings.appearance, .dark)
        XCTAssertFalse(themed.settings.waveformVisible)
        XCTAssertTrue(themed.settings.statusBarVisible)
        XCTAssertEqual(themed.playback(mediaID: library.playlist[0].id)?.position, 42)
        XCTAssertEqual(reopened.playlist.count, 1)
    }

    func testManualScrollPausesFollowUntilIdle() {
        var latch = SentenceFollowLatch(delay: 3.5)
        let start = Date(timeIntervalSince1970: 1_000)
        latch.userScrolled(at: start)
        XCTAssertFalse(latch.following)
        XCTAssertFalse(latch.resumeIfDue(at: start.addingTimeInterval(3)))
        XCTAssertTrue(latch.resumeIfDue(at: start.addingTimeInterval(3.5)))
        XCTAssertTrue(latch.following)

        latch.userScrolled(at: start)
        latch.userChoseSentence()
        XCTAssertTrue(latch.following)
        XCTAssertFalse(latch.resumeIfDue(at: start.addingTimeInterval(10)))
    }
}

final class WaveformCacheTests: XCTestCase {
    func testSecondReadDoesNotExtractAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extractor = CountingExtractor()
        let service = WaveformService(directory: directory, extractor: extractor)
        let media = directory.appendingPathComponent("tone.wav")
        let first = try await service.peaks(mediaID: "media", index: 3, url: media, start: 0, end: 1, buckets: 8)
        let second = try await service.peaks(mediaID: "media", index: 3, url: media, start: 0, end: 1, buckets: 8)
        XCTAssertEqual(first, second)
        XCTAssertEqual(extractor.calls, 1)
        let fresh = WaveformService(directory: directory, extractor: extractor)
        let third = try await fresh.peaks(mediaID: "media", index: 3, url: media, start: 0, end: 1, buckets: 8)
        XCTAssertEqual(third, first)
        XCTAssertEqual(extractor.calls, 1)
    }

    func testExtractorFailureIsAReadableError() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = WaveformService(directory: directory, extractor: FailingExtractor())
        do {
            _ = try await service.peaks(mediaID: "m", index: 0, url: directory, start: 0, end: 1)
            XCTFail("应该失败")
        } catch let error as PlayerError {
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("意外错误 \(error)")
        }
    }
}

final class SubtitleMatchTests: XCTestCase {
    func testSameNameAllowsLanguageSuffix() {
        XCTAssertTrue(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E01.srt"))
        XCTAssertTrue(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E01.en.srt"))
        XCTAssertTrue(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E01.zh.ass"))
        XCTAssertTrue(SubtitleMatch.matches(mediaFilename: "S01E01.mp4", subtitleFilename: "S01E01.lrc"))
        XCTAssertFalse(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E02.srt"))
        XCTAssertFalse(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E01.vtt"))
        XCTAssertFalse(SubtitleMatch.matches(mediaFilename: "S01E01.mkv", subtitleFilename: "S01E01.en.txt"))
    }

    func testPlayableQueueIsSameFolderSortedByName() {
        XCTAssertEqual(NetdiskCatalog.parentDirectory(of: "/show/S01E01.mkv"), "/show")
        XCTAssertEqual(NetdiskCatalog.parentDirectory(of: "/S01E01.mkv"), "/")
        let files = [
            NetdiskFile(fsID: 2, path: "/show/b.mp4", name: "b.mp4", isDirectory: false, size: 1, modified: nil),
            NetdiskFile(fsID: 3, path: "/show/a.zh.srt", name: "a.zh.srt", isDirectory: false, size: 1, modified: nil),
            NetdiskFile(fsID: 1, path: "/show/a.mkv", name: "a.mkv", isDirectory: false, size: 1, modified: nil),
            NetdiskFile(fsID: 4, path: "/show/notes", name: "notes", isDirectory: true, size: 0, modified: nil)
        ]
        XCTAssertEqual(NetdiskCatalog.playableSorted(files).map(\.name), ["a.mkv", "b.mp4"])
        XCTAssertEqual(NetdiskCatalog.subtitles(for: "a.mkv", in: files).map(\.name), ["a.zh.srt"])
    }
}

final class DownloadLogicTests: XCTestCase {
    func testRangeHeaderAndDlinkRefresh() throws {
        let url = URL(string: "https://example.com/file?foo=1")!
        let request = DownloadRequest.make(url: url, resumeFrom: 4096, accessToken: "token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4096-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pan.baidu.com")
        XCTAssertTrue(request.url?.absoluteString.contains("access_token=token") == true)
        XCTAssertTrue(DownloadRequest.shouldRefreshDlink(statusCode: 403, expiry: Date().addingTimeInterval(3600)))
        XCTAssertTrue(DownloadRequest.shouldRefreshDlink(statusCode: 200, expiry: Date().addingTimeInterval(10)))
        XCTAssertFalse(DownloadRequest.shouldRefreshDlink(statusCode: 200, expiry: Date().addingTimeInterval(3600)))
    }
}

@MainActor
final class NetdiskServiceTests: XCTestCase {
    func testMKVPromptsInsteadOfStreamingAndQueueIsSameFolder() async throws {
        let http = MockHTTP()
        http.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("method=list") {
                let body = #"{"errno":0,"list":[{"fs_id":1,"path":"/show/b.mp4","server_filename":"b.mp4","isdir":0,"size":10,"server_mtime":1},{"fs_id":2,"path":"/show/a.mkv","server_filename":"a.mkv","isdir":0,"size":10,"server_mtime":1},{"fs_id":3,"path":"/show/a.zh.srt","server_filename":"a.zh.srt","isdir":0,"size":20,"server_mtime":1}]}"#
                return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
            }
            if absolute.contains("method=filemetas") {
                let body = #"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file/a.zh.srt","size":20,"filename":"a.zh.srt"}]}"#
                return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponseBox(status: 200, headers: [:], body: Data(#"{"errno":0}"#.utf8))
        }
        let service = try makeNetdisk(http: http)
        let file = NetdiskFile(fsID: 2, path: "/show/a.mkv", name: "a.mkv", isDirectory: false, size: 10, modified: nil)
        let plan = await service.preparePlayback(file)
        guard case .blocked(let text) = plan else {
            return XCTFail("MKV 应该提示下载，实际 \(plan)")
        }
        XCTAssertTrue(text.contains("MKV"))
        XCTAssertEqual(service.playbackDirectory, "/show")
        XCTAssertEqual(service.playbackQueue.map(\.name), ["a.mkv", "b.mp4"])
    }

    func testSearchAndTokenRefresh() async throws {
        let http = MockHTTP()
        http.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("grant_type=refresh_token") {
                let body = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":2592000}"#
                return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
            }
            if absolute.contains("method=search") {
                let body = #"{"errno":0,"list":[{"fs_id":7,"path":"/英语/a.mp4","server_filename":"a.mp4","isdir":0,"size":100,"server_mtime":1700000000}]}"#
                return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
            }
            if absolute.contains("method=list") {
                return HTTPResponseBox(status: 200, headers: [:], body: Data(#"{"errno":0,"list":[]}"#.utf8))
            }
            if absolute.contains("api/quota") || absolute.contains("method=uinfo") {
                return HTTPResponseBox(status: 200, headers: [:], body: Data(#"{"errno":0,"used":1,"total":2,"netdisk_name":"learner"}"#.utf8))
            }
            return HTTPResponseBox(status: 200, headers: [:], body: Data(#"{"errno":0}"#.utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = try CacheManager(directory: directory)
        let store = try SQLiteStore(path: directory.appendingPathComponent("db.sqlite").path)
        let credentials = MemoryCredentialStore()
        try credentials.set("app", account: BaiduAccount.appKey)
        try credentials.set("secret", account: BaiduAccount.secret)
        try credentials.set("old", account: BaiduAccount.access)
        try credentials.set("old-refresh", account: BaiduAccount.refresh)
        try credentials.set(String(Date().addingTimeInterval(-10).timeIntervalSince1970), account: BaiduAccount.expiry)
        let service = NetdiskService(store: store, cache: cache, credentials: credentials, http: http, transport: MockTransport())
        await service.search("a")
        XCTAssertEqual(service.files.first?.name, "a.mp4")
        let refreshed = try credentials.string(account: BaiduAccount.access)
        XCTAssertEqual(refreshed, "new-access")
    }

    func testDeniedAuthorizationDoesNotBlockLocalMessage() async throws {
        let http = MockHTTP()
        http.handler = { request in
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("device/code") {
                let body = #"{"device_code":"dev","user_code":"ABCD","verification_url":"https://example.com","qrcode_url":"https://example.com/qr","interval":1}"#
                return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
            }
            let body = #"{"error":"access_denied"}"#
            return HTTPResponseBox(status: 200, headers: [:], body: Data(body.utf8))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = NetdiskService(
            store: try SQLiteStore(path: directory.appendingPathComponent("db.sqlite").path),
            cache: try CacheManager(directory: directory),
            credentials: MemoryCredentialStore(),
            http: http,
            transport: MockTransport()
        )
        service.saveCredentials(appKey: "app", secret: "secret")
        await service.startAuthorization()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        if case .failed(let message) = service.authPhase {
            XCTAssertTrue(message.contains("本地"))
        } else {
            XCTFail("授权被拒绝后应进入失败引导，当前 \(service.authPhase)")
        }
    }

    private func makeNetdisk(http: MockHTTP) throws -> NetdiskService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let credentials = MemoryCredentialStore()
        try credentials.set("app", account: BaiduAccount.appKey)
        try credentials.set("secret", account: BaiduAccount.secret)
        try credentials.set("token", account: BaiduAccount.access)
        try credentials.set("refresh", account: BaiduAccount.refresh)
        try credentials.set(String(Date().addingTimeInterval(86_400).timeIntervalSince1970), account: BaiduAccount.expiry)
        return NetdiskService(
            store: try SQLiteStore(path: directory.appendingPathComponent("db.sqlite").path),
            cache: try CacheManager(directory: directory),
            credentials: credentials,
            http: http,
            transport: MockTransport()
        )
    }
}

@MainActor
final class PlaybackSessionTests: XCTestCase {
    func testJumpSeeksToSentenceStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("clip.mp4")
        try Data("placeholder".utf8).write(to: media)
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello there

        2
        00:00:03,000 --> 00:00:05,000
        Next line
        """
        try srt.write(to: directory.appendingPathComponent("clip.srt"), atomically: true, encoding: .utf8)
        let store = try SQLiteStore(path: directory.appendingPathComponent("db.sqlite").path)
        let library = LibraryService(store: store)
        let waveforms = WaveformService(directory: directory.appendingPathComponent("waves"), extractor: CountingExtractor())
        let core = FakeCore()
        let session = PlaybackSession(core: core, library: library, waveforms: waveforms)
        let item = library.importLocal(urls: [media])[0]
        await session.open(item, autoplay: false)
        XCTAssertEqual(session.sentences.count, 2)
        session.jump(to: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(core.seeks.last ?? -1, 3, accuracy: 0.05)
        session.setOffset(0.12)
        session.jump(to: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(core.seeks.last ?? -1, 1.12, accuracy: 0.05)
        session.persist()
        let reopened = LibraryService(store: try SQLiteStore(path: directory.appendingPathComponent("db.sqlite").path))
        XCTAssertEqual(reopened.media(id: item.id)?.lastPosition ?? -1, session.currentTime, accuracy: 0.05)
        XCTAssertEqual(reopened.settings.lastMediaID, item.id)
    }

    func testDamagedAndUnsupportedDoNotCrash() async throws {
        let kit = AVPlayerKit()
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: text)
        do {
            try await kit.open(url: text)
            XCTFail("文本文件应被拒绝")
        } catch let error as PlayerError {
            XCTAssertNotNil(error.errorDescription)
        }
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("not-a-video".utf8).write(to: garbage)
        do {
            try await kit.open(url: garbage)
            XCTFail("损坏文件应被拒绝")
        } catch let error as PlayerError {
            XCTAssertNotNil(error.errorDescription)
        }
    }
}

final class WaveformExtractorTests: XCTestCase {
    func testGeneratedToneProducesPeaks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try WAVFixture.write(to: url, seconds: 0.4)
        let peaks = try await WaveformExtractor().extractPeaks(from: url, start: 0, end: 0.4, buckets: 16)
        XCTAssertEqual(peaks.count, 16)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.2)
    }
}

private final class CountingExtractor: WaveformExtracting, @unchecked Sendable {
    var calls = 0
    func extractPeaks(from url: URL, start: Double, end: Double, buckets: Int) async throws -> [Float] {
        calls += 1
        return Array(repeating: 0.4, count: buckets)
    }
}

private struct FailingExtractor: WaveformExtracting {
    func extractPeaks(from url: URL, start: Double, end: Double, buckets: Int) async throws -> [Float] {
        throw PlayerError.noAudioTrack
    }
}

private final class MockHTTP: HTTPClient, @unchecked Sendable {
    var handler: (URLRequest) throws -> HTTPResponseBox = { _ in
        HTTPResponseBox(status: 200, headers: [:], body: Data())
    }
    func send(_ request: URLRequest) async throws -> HTTPResponseBox {
        try handler(request)
    }
}

private final class MockTransport: DownloadTransport, @unchecked Sendable {
    func download(_ request: URLRequest, to destination: URL, append: Bool, onProgress: @escaping (Int64) -> Void) async throws {}
}

@MainActor
private final class FakeCore: MediaCoreProtocol {
    var currentTime: Double = 0
    var duration: Double = 30
    var isPlaying = false
    var volume: Float = 1
    var hasVideo = false
    var openedURL: URL?
    var seeks: [Double] = []
    var statusHandler: ((String) -> Void)?

    func open(url: URL) async throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) async {
        seeks.append(seconds)
        currentTime = seconds
    }
    func setRate(_ rate: Double) {}
    func setPitchPreservation(_ enabled: Bool) {}
    func setTimeObserver(_ handler: @escaping (Double) -> Void) {}
    func attachPreview(to view: NSView) {}
    func layoutPreview() {}
    func close() {}
}

private enum WAVFixture {
    static func write(to url: URL, seconds: Double, sampleRate: Double = 8000) throws {
        let count = Int(seconds * sampleRate)
        var data = Data()
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        let dataSize = UInt32(count * 2)
        let chunkSize = UInt32(36) + dataSize
        append(chunkSize, to: &data)
        data.append(contentsOf: [UInt8]("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: [UInt8]("data".utf8))
        append(dataSize, to: &data)
        for index in 0..<count {
            let sample = sin(2 * Double.pi * 440 * Double(index) / sampleRate)
            var value = Int16(sample * 12000).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
