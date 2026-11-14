import Foundation
import SwiftUI
import AVKit

/// アプリ内に保存した動画・音声の記録（実ファイルは Documents/Library 内）
/// LiveContainer ではパスの再構築が失敗することがあるため、
/// 登録時に実際に使えた絶対パスも一緒に保持し、そちらを優先して使う。
struct LibraryItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var storedPath: String     // Documents からの相対パス（例: Library/<id>.mp4）
    var absolutePath: String   // 登録時点で実在を確認した絶対パス
    var isAudio: Bool
    var savedAt: Date
    var sizeBytes: Int64

    var url: URL {
        let abs = URL(fileURLWithPath: absolutePath)
        if FileManager.default.fileExists(atPath: abs.path) { return abs }
        return DownloadManager.documentsDir.appendingPathComponent(storedPath)
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
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

    /// ダウンロード済みファイルを Library フォルダへ移し、実在するパスで登録する
    func add(title: String, file: URL, isAudio: Bool) -> LibraryItem {
        let id = UUID()
        let libDir = DownloadManager.documentsDir.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "mp4" : file.pathExtension
        let dest = libDir.appendingPathComponent(id.uuidString).appendingPathExtension(ext)

        var finalURL = file
        var storedPath = file.lastPathComponent
        if file.standardizedFileURL != dest.standardizedFileURL {
            do {
                try FileManager.default.moveItem(at: file, to: dest)
                finalURL = dest
                storedPath = "Library/\(dest.lastPathComponent)"
            } catch {
                // 移動できなければ元の場所のまま登録する
                finalURL = file
                storedPath = file.lastPathComponent
            }
        } else {
            storedPath = "Library/\(dest.lastPathComponent)"
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = LibraryItem(id: id, title: title, storedPath: storedPath,
                               absolutePath: finalURL.path, isAudio: isAudio,
                               savedAt: Date(), sizeBytes: size)
        items.insert(item, at: 0)
        persist()
        return item
    }

    func remove(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

/// アプリ内プレイヤー（シート競合を避けるため fullScreenCover で使う）
struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if FileManager.default.fileExists(atPath: url.path) {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                Text("ファイルが見つかりません")
                    .foregroundStyle(.white)
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
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
