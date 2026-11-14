import Foundation
import AVFoundation
import SwiftUI
import AVKit

/// アプリ内に保存した動画・音声の記録。
/// LiveContainer ではゲストアプリのデータ配置（コンテナUUID等）が変わり、
/// 保存しておいた絶対パスが指す場所にファイルが無いことがある。
/// そのため再生・保存の直前に「ファイル名」で実ファイルを探し直し、見つかれば記録を自己修復する。
struct LibraryItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var fileName: String = ""
    var absolutePath: String   // 最後に実在を確認できた絶対パス
    var isAudio: Bool
    var savedAt: Date
    var sizeBytes: Int64

    var url: URL {
        URL(fileURLWithPath: absolutePath)
    }

    var effectiveFileName: String {
        if !fileName.isEmpty { return fileName }
        return URL(fileURLWithPath: absolutePath).lastPathComponent
    }
}

final class LibraryStore: ObservableObject {
    @Published var items: [LibraryItem] = []

    private var indexURL: URL {
        DownloadManager.documentsDir.appendingPathComponent("library.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        items = decoded
    }

    /// ダウンロード済みファイルを「そのままの場所・パス」で登録する（移動しない）
    func add(title: String, file: URL, isAudio: Bool) -> LibraryItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = LibraryItem(id: UUID(), title: title, fileName: file.lastPathComponent,
                               absolutePath: file.path, isAudio: isAudio,
                               savedAt: Date(), sizeBytes: size)
        items.insert(item, at: 0)
        persist()
        return item
    }

    func remove(_ item: LibraryItem) {
        if let url = resolve(item) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// 実ファイルの現在の場所を解決する。見つかれば記録のパスを更新（自己修復）して返す。
    func resolve(_ item: LibraryItem) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: item.absolutePath) {
            return URL(fileURLWithPath: item.absolutePath)
        }
        let name = item.effectiveFileName
        let docs = DownloadManager.documentsDir
        let candidates = [
            docs.appendingPathComponent(name),
            docs.appendingPathComponent("Library").appendingPathComponent(name),
        ]
        for c in candidates where fm.fileExists(atPath: c.path) {
            heal(item, to: c)
            return c
        }
        // コンテナ配置が変わっている場合に備え、ファイル名で再帰検索する
        var roots: [URL] = [docs]
        var root = URL(fileURLWithPath: item.absolutePath)
        for _ in 0..<5 { root = root.deletingLastPathComponent() }
        if root.path != docs.path { roots.append(root) }
        for r in roots {
            if let found = search(r, fileName: name) {
                heal(item, to: found)
                return found
            }
        }
        return nil
    }

    private func search(_ root: URL, fileName: String) -> URL? {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in en {
            if url.lastPathComponent == fileName { return url }
        }
        return nil
    }

    private func heal(_ item: LibraryItem, to url: URL) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].absolutePath = url.path
        items[idx].fileName = url.lastPathComponent
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

/// ライブラリ行のサムネイル（動画は1秒地点のフレーム、音声はアイコン）
struct ThumbnailView: View {
    let item: LibraryItem
    let store: LibraryStore
    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.isAudio ? "music.note" : "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task { await load() }
    }

    private func load() async {
        guard !item.isAudio, image == nil, let url = store.resolve(item) else { return }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 192, height: 192)
        if let result = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
            image = UIImage(cgImage: result.image)
        }
    }
}

/// アプリ内プレイヤー（fullScreenCover で使う）。再生失敗時は実際のエラーとパスを表示する。
struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer
    @State private var errorText = ""
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            if !errorText.isEmpty {
                VStack(spacing: 8) {
                    Text("再生できませんでした")
                        .foregroundStyle(.white)
                        .font(.headline)
                    Text(errorText)
                        .foregroundStyle(.white)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Text(url.path)
                        .foregroundStyle(.gray)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = (attrs[.size] as? NSNumber)?.int64Value {
                        Text("容量: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                            .foregroundStyle(.gray)
                            .font(.caption2)
                    } else {
                        Text("容量: 取得できませんでした")
                            .foregroundStyle(.gray)
                            .font(.caption2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .gray)
            }
            .padding()
        }
        .onAppear {
            player.play()
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let item = player.currentItem, item.status == .failed {
                    let ns = item.error as NSError?
                    errorText = "\(item.error?.localizedDescription ?? "不明なエラー") [\(ns?.domain ?? "-") \(ns?.code ?? 0)]"
                }
            }
        }
        .onDisappear { player.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem)) { note in
            if let e = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError {
                errorText = "\(e.localizedDescription) [\(e.domain) \(e.code)]"
            }
        }
    }
}
