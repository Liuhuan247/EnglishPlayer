import Foundation
import SQLite3

/// 媒体、句子、进度、缓存索引和设置都进这一份库。网盘 Token 不在这里。
final class SQLiteStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "EnglishPlayer.sqlite")
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        if !parent.path.isEmpty, parent.path != "/" {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &pointer, flags, nil) == SQLITE_OK else {
            throw PlayerError.database("无法打开资料库")
        }
        db = pointer
        try queue.sync {
            try self.migrateLocked()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func upsertMedia(_ item: MediaItem) throws {
        let sql = """
        INSERT INTO media_items
            (id, source, path, cache_path, title, duration, last_position, subtitle_offset, subtitle_refs, wave_ref, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            source = excluded.source,
            path = excluded.path,
            cache_path = excluded.cache_path,
            title = excluded.title,
            duration = excluded.duration,
            last_position = excluded.last_position,
            subtitle_offset = excluded.subtitle_offset,
            subtitle_refs = excluded.subtitle_refs,
            wave_ref = excluded.wave_ref,
            updated_at = excluded.updated_at
        """
        try withStatement(sql, [
            .text(item.id),
            .text(item.source.rawValue),
            .text(item.path),
            item.cachePath.map(Bind.text) ?? .null,
            .text(item.title),
            .double(item.duration),
            .double(item.lastPosition),
            .double(item.subtitleOffset),
            .text(Self.encode(item.subtitleRefs)),
            item.waveRef.map(Bind.text) ?? .null,
            .double(item.updatedAt.timeIntervalSince1970)
        ]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw self.lastErrorLocked() }
        }
    }

    func media(id: String) throws -> MediaItem? {
        try queryMedia("SELECT * FROM media_items WHERE id = ?", [.text(id)]).first
    }

    func media(path: String) throws -> MediaItem? {
        try queryMedia("SELECT * FROM media_items WHERE path = ?", [.text(path)]).first
    }

    func allMedia() throws -> [MediaItem] {
        try queryMedia("SELECT * FROM media_items ORDER BY updated_at DESC", [])
    }

    func deleteMedia(id: String) throws {
        try run("DELETE FROM sentences WHERE media_id = ?", [.text(id)])
        try run("DELETE FROM playback_state WHERE media_id = ?", [.text(id)])
        try run("DELETE FROM playlist WHERE media_id = ?", [.text(id)])
        try run("DELETE FROM media_items WHERE id = ?", [.text(id)])
    }

    func replaceSentences(mediaID: String, _ sentences: [Sentence]) throws {
        try queue.sync {
            try self.execLocked("BEGIN")
            do {
                try self.runLocked("DELETE FROM sentences WHERE media_id = ?", [.text(mediaID)])
                for sentence in sentences {
                    try self.runLocked(
                        """
                        INSERT INTO sentences (id, media_id, idx, start_time, end_time, text_en, text_zh)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(sentence.id),
                            .text(sentence.mediaID),
                            .int(Int64(sentence.index)),
                            .double(sentence.startTime),
                            .double(sentence.endTime),
                            .text(sentence.textEn),
                            .text(sentence.textZh)
                        ]
                    )
                }
                try self.execLocked("COMMIT")
            } catch {
                try? self.execLocked("ROLLBACK")
                throw error
            }
        }
    }

    func sentences(mediaID: String) throws -> [Sentence] {
        let sql = "SELECT id, media_id, idx, start_time, end_time, text_en, text_zh FROM sentences WHERE media_id = ? ORDER BY idx"
        return try withStatement(sql, [.text(mediaID)]) { stmt in
            var rows: [Sentence] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Sentence(
                    id: columnText(stmt, 0),
                    mediaID: columnText(stmt, 1),
                    index: Int(sqlite3_column_int(stmt, 2)),
                    startTime: sqlite3_column_double(stmt, 3),
                    endTime: sqlite3_column_double(stmt, 4),
                    textEn: columnText(stmt, 5),
                    textZh: columnText(stmt, 6)
                ))
            }
            return rows
        }
    }

    func savePlayback(_ record: PlaybackRecord) throws {
        try run(
            """
            INSERT INTO playback_state (media_id, position, rate, loop_mode)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(media_id) DO UPDATE SET
                position = excluded.position,
                rate = excluded.rate,
                loop_mode = excluded.loop_mode
            """,
            [.text(record.mediaID), .double(record.position), .double(record.rate), .text(record.loopMode.rawValue)]
        )
    }

    func playback(mediaID: String) throws -> PlaybackRecord? {
        let sql = "SELECT media_id, position, rate, loop_mode FROM playback_state WHERE media_id = ?"
        return try withStatement(sql, [.text(mediaID)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return PlaybackRecord(
                mediaID: columnText(stmt, 0),
                position: sqlite3_column_double(stmt, 1),
                rate: sqlite3_column_double(stmt, 2),
                loopMode: LoopMode(rawValue: columnText(stmt, 3)) ?? .off
            )
        }
    }

    func playlistIDs() throws -> [String] {
        try withStatement("SELECT media_id FROM playlist ORDER BY position", []) { stmt in
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(columnText(stmt, 0))
            }
            return ids
        }
    }

    func setPlaylist(_ ids: [String]) throws {
        try queue.sync {
            try self.execLocked("BEGIN")
            do {
                try self.execLocked("DELETE FROM playlist")
                for (index, id) in ids.enumerated() {
                    try self.runLocked(
                        "INSERT INTO playlist (position, media_id) VALUES (?, ?)",
                        [.int(Int64(index)), .text(id)]
                    )
                }
                try self.execLocked("COMMIT")
            } catch {
                try? self.execLocked("ROLLBACK")
                throw error
            }
        }
    }

    func upsertCache(_ entry: CacheEntry) throws {
        try run(
            """
            INSERT INTO cache_entries
                (media_id, netdisk_path, fs_id, local_path, size, bytes_downloaded, status, dlink, dlink_expiry, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(media_id) DO UPDATE SET
                netdisk_path = excluded.netdisk_path,
                fs_id = excluded.fs_id,
                local_path = excluded.local_path,
                size = excluded.size,
                bytes_downloaded = excluded.bytes_downloaded,
                status = excluded.status,
                dlink = excluded.dlink,
                dlink_expiry = excluded.dlink_expiry,
                updated_at = excluded.updated_at
            """,
            [
                .text(entry.mediaID),
                .text(entry.netdiskPath),
                .int(entry.fsID),
                .text(entry.localPath),
                .int(entry.size),
                .int(entry.bytesDownloaded),
                .text(entry.status.rawValue),
                entry.dlink.map(Bind.text) ?? .null,
                entry.dlinkExpiry.map { Bind.double($0.timeIntervalSince1970) } ?? .null,
                .double(entry.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    func cacheEntries() throws -> [CacheEntry] {
        try queryCache("SELECT * FROM cache_entries ORDER BY updated_at DESC", [])
    }

    func cache(mediaID: String) throws -> CacheEntry? {
        try queryCache("SELECT * FROM cache_entries WHERE media_id = ?", [.text(mediaID)]).first
    }

    func deleteCache(mediaID: String) throws {
        try run("DELETE FROM cache_entries WHERE media_id = ?", [.text(mediaID)])
    }

    func setSetting(_ key: String, _ value: String) throws {
        try run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    func setting(_ key: String) throws -> String? {
        try withStatement("SELECT value FROM settings WHERE key = ?", [.text(key)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return columnText(stmt, 0)
        }
    }

    func allSettings() throws -> [String: String] {
        try withStatement("SELECT key, value FROM settings", []) { stmt in
            var map: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                map[columnText(stmt, 0)] = columnText(stmt, 1)
            }
            return map
        }
    }

    private func queryMedia(_ sql: String, _ binds: [Bind]) throws -> [MediaItem] {
        try withStatement(sql, binds) { stmt in
            var rows: [MediaItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(MediaItem(
                    id: columnText(stmt, 0),
                    source: MediaSource(rawValue: columnText(stmt, 1)) ?? .local,
                    path: columnText(stmt, 2),
                    cachePath: columnOptional(stmt, 3),
                    title: columnText(stmt, 4),
                    duration: sqlite3_column_double(stmt, 5),
                    lastPosition: sqlite3_column_double(stmt, 6),
                    subtitleOffset: sqlite3_column_double(stmt, 7),
                    subtitleRefs: Self.decode(columnText(stmt, 8)),
                    waveRef: columnOptional(stmt, 9),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                ))
            }
            return rows
        }
    }

    private func queryCache(_ sql: String, _ binds: [Bind]) throws -> [CacheEntry] {
        try withStatement(sql, binds) { stmt in
            var rows: [CacheEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let expiry = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                rows.append(CacheEntry(
                    mediaID: columnText(stmt, 0),
                    netdiskPath: columnText(stmt, 1),
                    fsID: sqlite3_column_int64(stmt, 2),
                    localPath: columnText(stmt, 3),
                    size: sqlite3_column_int64(stmt, 4),
                    bytesDownloaded: sqlite3_column_int64(stmt, 5),
                    status: CacheStatus(rawValue: columnText(stmt, 6)) ?? .pending,
                    dlink: columnOptional(stmt, 7),
                    dlinkExpiry: expiry,
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                ))
            }
            return rows
        }
    }

    private func migrateLocked() throws {
        let statements = [
            "PRAGMA journal_mode=WAL;",
            "PRAGMA foreign_keys=ON;",
            """
            CREATE TABLE IF NOT EXISTS media_items (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                path TEXT NOT NULL,
                cache_path TEXT,
                title TEXT NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                last_position REAL NOT NULL DEFAULT 0,
                subtitle_offset REAL NOT NULL DEFAULT 0,
                subtitle_refs TEXT NOT NULL DEFAULT '[]',
                wave_ref TEXT,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sentences (
                id TEXT PRIMARY KEY,
                media_id TEXT NOT NULL,
                idx INTEGER NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                text_en TEXT NOT NULL,
                text_zh TEXT NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_sentences_media ON sentences(media_id, idx);",
            """
            CREATE TABLE IF NOT EXISTS playback_state (
                media_id TEXT PRIMARY KEY,
                position REAL NOT NULL,
                rate REAL NOT NULL,
                loop_mode TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS playlist (
                position INTEGER PRIMARY KEY,
                media_id TEXT NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS cache_entries (
                media_id TEXT PRIMARY KEY,
                netdisk_path TEXT NOT NULL,
                fs_id INTEGER NOT NULL,
                local_path TEXT NOT NULL,
                size INTEGER NOT NULL,
                bytes_downloaded INTEGER NOT NULL,
                status TEXT NOT NULL,
                dlink TEXT,
                dlink_expiry REAL,
                updated_at REAL NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        ]
        for sql in statements {
            try execLocked(sql)
        }
    }

    private func run(_ sql: String, _ binds: [Bind]) throws {
        try withStatement(sql, binds) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw self.lastErrorLocked() }
        }
    }

    private func runLocked(_ sql: String, _ binds: [Bind]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastErrorLocked() }
        defer { sqlite3_finalize(stmt) }
        for (offset, bind) in binds.enumerated() {
            apply(bind, to: stmt, index: Int32(offset + 1))
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastErrorLocked() }
    }

    private func withStatement<T>(_ sql: String, _ binds: [Bind], _ body: (OpaquePointer?) throws -> T) throws -> T {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw self.lastErrorLocked()
            }
            defer { sqlite3_finalize(stmt) }
            for (offset, bind) in binds.enumerated() {
                self.apply(bind, to: stmt, index: Int32(offset + 1))
            }
            return try body(stmt)
        }
    }

    private func execLocked(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw lastErrorLocked()
        }
    }

    private func apply(_ bind: Bind, to stmt: OpaquePointer?, index: Int32) {
        switch bind {
        case .text(let value):
            let ns = value as NSString
            sqlite3_bind_text(stmt, index, ns.utf8String, -1, transient)
        case .double(let value):
            sqlite3_bind_double(stmt, index, value)
        case .int(let value):
            sqlite3_bind_int64(stmt, index, value)
        case .null:
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: raw)
    }

    private func columnOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        let text = columnText(stmt, index)
        return text.isEmpty ? nil : text
    }

    private func lastErrorLocked() -> PlayerError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        return .database(message)
    }

    private static func encode(_ refs: [String]) -> String {
        guard let data = try? JSONEncoder().encode(refs), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func decode(_ text: String) -> [String] {
        guard let data = text.data(using: .utf8), let refs = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return refs
    }
}

private enum Bind {
    case text(String)
    case double(Double)
    case int(Int64)
    case null
}
