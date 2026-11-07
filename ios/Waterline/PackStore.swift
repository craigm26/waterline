import Foundation
import CryptoKit
import CoreLocation

/// Downloadable data packs (packs/manifest.json, release assets on GitHub). Files land in
/// Documents/Waterline/<pack id>/, which the Files app shows under On My iPhone › Waterline, so
/// raw LAZ and GeoTIFF files can be opened in other apps. The folder is excluded from iCloud
/// backup because everything in it can be downloaded again.
@MainActor
final class PackStore: ObservableObject {
    struct Manifest: Decodable { let schema: String; let release: String; let packs: [Pack]; let groups: [Group]? }
    /// A place. Every pack belongs to one; the Offline data screen shows them collapsed.
    struct Group: Decodable, Identifiable {
        struct Source: Decodable { let url: URL; let tiles: Int; let bytes: Int64 }
        let id: String, name: String, state: String
        let bbox: [Double]
        let why: String?, caveat: String?
        let usgs_1m: Source?
        let live: LiveLayers.Feeds?
        let sensors: SensorFeeds?
        let datasets: [Dataset]?
        let adopt: Adopt?
        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            bbox.count == 4 && (bbox[0]...bbox[2]).contains(c.longitude) && (bbox[1]...bbox[3]).contains(c.latitude)
        }
        var center: CLLocationCoordinate2D { .init(latitude: (bbox[1] + bbox[3]) / 2, longitude: (bbox[0] + bbox[2]) / 2) }
    }
    /// One line in a place's list: how the phone gets this data (scripts/build_catalog.py).
    struct Dataset: Decodable, Identifiable {
        let id: String, section: String, name: String, detail: String, source: String, access: String
        let pack: String?, url: URL?
    }
    /// A volunteer drain program. The app links to it and never signs anyone up.
    struct Adopt: Decodable {
        let status: String, name: String?, `operator`: String?, url: URL?, detail: String
        var isOpen: Bool { status != "none" && url != nil }
    }
    struct Pack: Decodable, Identifiable {
        struct File: Decodable { let name: String; let url: URL; let bytes: Int64; let sha256: String }
        let id: String, kind: String, version: Int, title: String, summary: String
        let files: [File]
        let total_bytes: Int64
        let license: String?
        let bbox: [Double]?
        let group: String?, label: String?
        var shortTitle: String { label ?? title }
    }
    enum State: Equatable { case notInstalled, downloading(Double), verifying, installed, failed(String) }

    static let shared = PackStore()
    nonisolated static let manifestURL = URL(string: "https://raw.githubusercontent.com/craigm26/waterline/main/packs/manifest.json")!

    @Published var manifest: Manifest?
    @Published var manifestError: String?
    @Published var states: [String: State] = [:]

    private var jobs: [String: Task<Void, Never>] = [:]

    nonisolated static var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Waterline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var u = d, v = URLResourceValues(); v.isExcludedFromBackup = true
            try? u.setResourceValues(v)
        }
        return d
    }
    nonisolated static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    nonisolated private static func marker(_ id: String) -> URL { folder(id).appendingPathComponent(".installed.json") }

    /// Installed version of a pack, read from disk (works before the manifest loads, and offline).
    nonisolated static func installedVersion(_ id: String) -> Int? {
        guard let d = try? Data(contentsOf: marker(id)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["version"] as? Int
    }
    nonisolated static func file(_ id: String, _ name: String) -> URL? {
        guard installedVersion(id) != nil else { return nil }
        let u = folder(id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func load() async {
        do {
            let m: Manifest = try await Net.freshJSON(Self.manifestURL, cacheName: "packs-manifest.json")
            manifest = m
            manifestError = nil
            for p in m.packs where states[p.id] == nil || states[p.id] == .notInstalled || states[p.id] == .installed {
                states[p.id] = Self.installedVersion(p.id).map { $0 >= p.version ? .installed : .notInstalled } ?? .notInstalled
            }
        } catch {
            manifestError = "Couldn't load the pack list. Check your connection and try again."
        }
    }

    func bytesOnDisk(_ id: String) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.folder(id).path) else { return 0 }
        return names.reduce(0) { n, f in
            n + ((try? fm.attributesOfItem(atPath: Self.folder(id).appendingPathComponent(f).path)[.size] as? Int64) ?? 0)
        }
    }

    func download(_ p: Pack) {
        guard jobs[p.id] == nil else { return }
        states[p.id] = .downloading(0)
        jobs[p.id] = Task {
            defer { jobs[p.id] = nil }
            do {
                let dir = Self.folder(p.id)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var done: Int64 = 0
                for f in p.files {
                    let dest = dir.appendingPathComponent(f.name)
                    if FileManager.default.fileExists(atPath: dest.path), await Self.hash(dest) == f.sha256 {
                        done += f.bytes; continue   // already here from an interrupted run
                    }
                    let watcher = TaskWatcher()
                    let base = done, total = max(p.total_bytes, 1)
                    let poll = Task { [weak self] in
                        while !Task.isCancelled {
                            if let t = watcher.task {
                                self?.states[p.id] = .downloading(Double(base + t.countOfBytesReceived) / Double(total))
                            }
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                    }
                    let (tmp, resp) = try await URLSession.shared.download(from: f.url, delegate: watcher)
                    poll.cancel()
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    states[p.id] = .verifying
                    guard await Self.hash(tmp) == f.sha256 else {
                        try? FileManager.default.removeItem(at: tmp)
                        throw NSError(domain: "Waterline", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(f.name) didn't match its checksum"])
                    }
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    done += f.bytes
                    states[p.id] = .downloading(Double(done) / Double(total))
                }
                let mark = try JSONSerialization.data(withJSONObject: ["version": p.version, "id": p.id])
                try mark.write(to: Self.marker(p.id))
                states[p.id] = .installed
                Self.reloadReaders()
            } catch is CancellationError {
                states[p.id] = .notInstalled
            } catch {
                states[p.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(_ id: String) { jobs[id]?.cancel(); jobs[id] = nil; states[id] = .notInstalled }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: Self.folder(id))
        states[id] = .notInstalled
        Self.reloadReaders()
    }

    /// The drain program for the place holding this spot, when one takes sign-ups.
    func adopt(at c: CLLocationCoordinate2D) -> Adopt? {
        manifest?.groups?.first { $0.contains(c) }?.adopt.flatMap { $0.isOpen ? $0 : nil }
    }

    func packs(in group: String) -> [Pack] { manifest?.packs.filter { $0.group == group } ?? [] }

    /// Everything in a group that isn't on the phone yet, smallest first so the useful layers land early.
    func downloadAll(in group: String) {
        for p in packs(in: group).sorted(by: { $0.total_bytes < $1.total_bytes }) where states[p.id] == .notInstalled || states[p.id] == nil {
            download(p)
        }
    }

    nonisolated private static func reloadReaders() {
        Ground1m.reload(); ElevationGrid.reloadRegions(); Places.reload(); LidarScene.reload()
    }

    /// SHA-256 of a file, streamed in 1 MB chunks off the main actor.
    nonisolated static func hash(_ url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            var sha = SHA256()
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// Captures the URLSessionTask behind an async download so its byte count can be polled.
final class TaskWatcher: NSObject, URLSessionTaskDelegate {
    var task: URLSessionTask?
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { self.task = task }
}

/// A 1 m ground pack (build_packs.py for SF, build_region_packs.py elsewhere): 500 m tiles of int16
/// cm NAVD88, raw deflate, read one tile at a time from disk. Covers land at or below about 30 ft.
final class Ground1m {
    private struct Header: Decodable {
        struct Tile: Decodable { let tx: Int; let ty: Int; let offset: Int; let bytes: Int }
        let x0: Double, y0: Double, tile_m: Int, res_m: Double, nodata: Int
        let zone: Int?
        let tiles: [Tile]
    }

    private static var cached: [Ground1m]?
    private static let lock = NSLock()

    /// Every installed 1 m pack.
    private static var all: [Ground1m] {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: PackStore.root.path)) ?? []
        let out: [Ground1m] = names.filter { $0.hasSuffix("-ground-1m") }.compactMap { id in
            let stem = String(id.dropLast("-ground-1m".count))
            return PackStore.file(id, "\(stem)_ground_1m.bin").flatMap { Ground1m(url: $0) }
        }
        cached = out
        return out
    }
    static func reload() { lock.lock(); cached = nil; lock.unlock() }

    /// Ground here from whichever pack covers it, or nil when none does.
    static func ground(_ c: CLLocationCoordinate2D) -> Double? {
        for g in all { if let v = g.groundNAVD88Ft(c) { return v } }
        return nil
    }

    private let url: URL
    private let h: Header
    private let base: Int
    private let index: [Int: Header.Tile]
    private var tiles: [Int: [Int16]] = [:]
    private var order: [Int] = []
    private let tileLock = NSLock()

    private init?(url u: URL) {
        guard let fh = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? fh.close() }
        // the header is one JSON line, up to a few hundred KB with thousands of tiles
        guard let head = try? fh.read(upToCount: 1 << 20), let nl = head.firstIndex(of: 0x0A),
              let hdr = try? JSONDecoder().decode(Header.self, from: head[head.startIndex..<nl]) else { return nil }
        url = u; h = hdr; base = nl - head.startIndex + 1
        var idx: [Int: Header.Tile] = [:]
        for t in hdr.tiles { idx[t.ty * 10_000 + t.tx] = t }
        index = idx
    }

    /// Ground at this spot in ft NAVD88, or nil outside the pack's tiles / off land.
    func groundNAVD88Ft(_ c: CLLocationCoordinate2D) -> Double? {
        let p = Geo.utm(lon: c.longitude, lat: c.latitude, zone: h.zone ?? 10)
        let tm = Double(h.tile_m)
        let tx = Int(((p.x - h.x0) / tm).rounded(.down)), ty = Int(((h.y0 - p.y) / tm).rounded(.down))
        guard let t = index[ty * 10_000 + tx], let cells = tile(t) else { return nil }
        let col = Int((p.x - h.x0 - Double(tx) * tm) / h.res_m), row = Int((h.y0 - Double(ty) * tm - p.y) / h.res_m)
        let n = h.tile_m
        guard row >= 0, row < n, col >= 0, col < n else { return nil }
        let v = cells[row * n + col]
        return Int(v) == h.nodata ? nil : Geo.feet(Double(v) / 100)
    }

    private func tile(_ t: Header.Tile) -> [Int16]? {
        let key = t.ty * 10_000 + t.tx
        tileLock.lock(); defer { tileLock.unlock() }
        if let c = tiles[key] { return c }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(base + t.offset))
        guard let blob = try? fh.read(upToCount: t.bytes),
              let raw = try? (blob as NSData).decompressed(using: .zlib) as Data else { return nil }
        let cells = raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        tiles[key] = cells; order.append(key)
        if order.count > 6 { tiles[order.removeFirst()] = nil }   // ~3 MB of tiles kept
        return cells
    }
}
