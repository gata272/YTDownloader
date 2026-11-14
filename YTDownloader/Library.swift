import Foundation
import SwiftUI
import AVKit

/// アプリ内に保存した動画・音声の記録。
/// ダウンロード直後のファイルURL（絶対パス）をそのまま保持し、
/// 移動もパスの再構築もしない（LiveContainer 環境でパス変換が絡むと実ファイルに届かなくなるため）。
/// 存在チェックで弾かず、再生・保存は実際に行って結果で判断する。
struct LibraryItem: Identifiable, Codable {
    var id: UUID
    var title: String
    var absolutePath: String   // ダウンロードが返したファイルの絶対パス（そのまま使う）
    var isAudio: Bool
    var savedAt: Date
    var sizeBytes: Int64

    var url: URL {
        URL(fileURLWithPath: absolutePath)
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
        let item = LibraryItem(id: UUID(), title: title, absolutePath: file.path,
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

/// アプリ内プレイヤー（fullScreenCover で使う）。再生失敗時は実際のエラーを表示する。
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
