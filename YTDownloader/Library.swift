import Foundation
import SwiftUI
import AVKit

/// アプリ内に保存した動画・音声の記録（実ファイルは Documents 内）
struct LibraryItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var fileName: String
    var isAudio: Bool
    var savedAt: Date
    var sizeBytes: Int64

    var url: URL {
        DownloadManager.documentsDir.appendingPathComponent(fileName)
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
        // 実ファイルが残っているものだけ表示する
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    @discardableResult
    func add(title: String, file: URL, isAudio: Bool) -> LibraryItem {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = LibraryItem(id: UUID(), title: title, fileName: file.lastPathComponent,
                               isAudio: isAudio, savedAt: Date(), sizeBytes: size)
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

/// アプリ内プレイヤー
struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
    }
}
