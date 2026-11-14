import SwiftUI
import UIKit

struct DownloadOption: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let video: YTFormat
    let audio: YTFormat?
    let audioOnly: Bool
}

struct ContentView: View {
    @State private var urlText = ""
    @State private var info: VideoInfo? = nil
    @State private var options: [DownloadOption] = []
    @State private var status = ""
    @State private var isError = false
    @State private var isBusy = false
    @State private var progress: Double? = nil
    @State private var resultFile: URL? = nil
    @State private var resultIsAudio = false
    @State private var savedNote = ""
    @State private var triedClients: Set<String> = []
    @State private var showLogin = false
    @State private var signedIn = false
    @State private var useCookies = false
    @StateObject private var library = LibraryStore()
    @State private var playingItem: LibraryItem? = nil
    @State private var resultItem: LibraryItem? = nil

    private let downloader = DownloadManager()

    var body: some View {
        NavigationStack {
            Form {
                Section("サインイン（bot確認の回避）") {
                    HStack {
                        Text(signedIn ? "状態：サインイン済み" : "状態：未サインイン")
                            .font(.footnote)
                        Spacer()
                        if signedIn {
                            Button("サインアウト") {
                                Task {
                                    await SessionManager.clearAll()
                                    signedIn = false
                                    status = "サインアウトしました"
                                    isError = false
                                }
                            }
                            .font(.footnote)
                        }
                    }
                    Button("YouTubeにサインイン") { showLogin = true }
                    Text("サインインはGoogleの公式ページ上で行います。パスワードがこのアプリに渡ることはありません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("サインインのCookieを取得に使う", isOn: $useCookies)
                    Text("ONにすると取得時にWebKitへアクセスします。「取得」でアプリが落ちる場合はOFFのまま使ってください。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("YouTubeのリンク") {
                    TextField("https://www.youtube.com/watch?v=…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("貼り付け") {
                            if let s = UIPasteboard.general.string { urlText = s }
                        }
                        Spacer()
                        Button("取得") { Task { await fetch() } }
                            .disabled(isBusy || urlText.isEmpty)
                    }
                }

                if let info {
                    Section("動画") {
                        Text(info.title).font(.headline)
                        Text("取得方式: \(info.clientName)").font(.caption).foregroundStyle(.secondary)
                        if !info.fetchLog.isEmpty {
                            Text(info.fetchLog).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Section("ダウンロード形式") {
                        ForEach(options) { opt in
                            Button {
                                Task { await runDownload(opt) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(opt.label)
                                        Text(opt.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                }
                            }
                            .disabled(isBusy)
                        }
                    }
                }

                if let progress {
                    Section("進捗") {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%").font(.caption)
                    }
                }

                if let resultFile {
                    Section("保存先") {
                        if let resultItem {
                            Button("アプリ内で再生") { playingItem = resultItem }
                            Text("ライブラリに保存済み").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("アプリ内に保存（ライブラリ）") { registerResult() }
                        }
                        if !resultIsAudio {
                            Button("写真アプリに保存") { Task { await savePhotos(resultFile, audio: false) } }
                        } else {
                            Button("写真アプリに保存（音声）") { Task { await savePhotos(resultFile, audio: true) } }
                        }
                        ShareLink(item: resultFile) {
                            Text("共有（ファイルに保存など）")
                        }
                        if !savedNote.isEmpty {
                            Text(savedNote).font(.caption).foregroundStyle(.green)
                        }
                    }
                }

                if !library.items.isEmpty {
                    Section("ライブラリ") {
                        ForEach(library.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text("\(item.isAudio ? "音声" : "動画") / \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) / \(item.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.absolutePath)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack(spacing: 16) {
                                    Button("再生") { playingItem = item }
                                    Button("写真へ") { Task { await savePhotos(item.url, audio: item.isAudio) } }
                                    ShareLink(item: item.url) { Text("共有") }
                                    Spacer()
                                    Button("削除", role: .destructive) { library.remove(item) }
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }

                if !status.isEmpty {
                    Section("状態") {
                        Text(status).font(.footnote).foregroundStyle(isError ? .red : .primary)
                    }
                }
            }
            .fullScreenCover(item: $playingItem) { item in
                PlayerView(url: item.url)
            }
            .navigationTitle("YTダウンローダ")
            .sheet(isPresented: $showLogin, onDismiss: {
                Task { signedIn = await SessionManager.isSignedIn() }
            }) {
                WebLoginView { showLogin = false }
            }
        }
    }

    private func fetch() async {
        triedClients = []
        await doFetch()
    }

    private func doFetch() async {
        guard let vid = Innertube.extractVideoID(from: urlText) else {
            status = "YouTubeのリンクから動画IDを読み取れませんでした"
            isError = true
            return
        }
        isBusy = true
        status = "取得中…"
        isError = false
        resultFile = nil
        resultItem = nil
        defer { isBusy = false }
        do {
            let v = try await Innertube.fetchInfo(videoID: vid, excluding: triedClients, useCookies: useCookies)
            triedClients.insert(v.clientName)
            info = v
            options = buildOptions(v)
            status = options.isEmpty ? "使える形式が見つかりませんでした" : ""
            isError = options.isEmpty
        } catch {
            info = nil
            options = []
            status = error.localizedDescription
            isError = true
        }
    }

    private func buildOptions(_ v: VideoInfo) -> [DownloadOption] {
        var out: [DownloadOption] = []
        for f in v.muxed where f.mimeType.contains("mp4") {
            out.append(DownloadOption(label: "\(f.qualityLabel) 動画", detail: "単一ファイル / mp4",
                                      video: f, audio: nil, audioOnly: false))
        }
        if let bestV = v.videos.first(where: { $0.mimeType.contains("mp4") && $0.codecIsMP4Friendly }),
           let bestA = v.audios.first(where: { $0.mimeType.contains("mp4") }) {
            out.append(DownloadOption(label: "\(bestV.qualityLabel) 動画（高画質）", detail: "映像+音声を結合 / mp4",
                                      video: bestV, audio: bestA, audioOnly: false))
        }
        if let a = v.audios.first {
            let ext = a.mimeType.contains("mp4") ? "m4a" : "webm"
            out.append(DownloadOption(label: "音声のみ", detail: "\(ext) / \(a.bitrate / 1000)kbps",
                                      video: a, audio: nil, audioOnly: true))
        }
        return out
    }

    private func runDownload(_ opt: DownloadOption) async {
        guard let v = info else { return }
        isBusy = true
        progress = 0
        status = "ダウンロード中…"
        isError = false
        defer { isBusy = false; progress = nil }
        do {
            let first = try await downloader.download(urlString: opt.video.url, userAgent: v.userAgent, clientNameHeader: v.clientNameHeader, clientVersion: v.clientVersion, visitorData: v.visitorData) { p in
                Task { @MainActor in progress = p }
            }
            var final = first
            if let audioFmt = opt.audio {
                status = "音声をダウンロード中…"
                let audioFile = try await downloader.download(urlString: audioFmt.url, userAgent: v.userAgent, clientNameHeader: v.clientNameHeader, clientVersion: v.clientVersion, visitorData: v.visitorData) { p in
                    Task { @MainActor in progress = p }
                }
                status = "結合中…"
                final = try await MediaTools.mux(video: first, audio: audioFile)
            }
            if opt.audioOnly, !opt.video.mimeType.contains("mp4") {
                // webm音声はそのままでは写真に保存できないため共有のみ
                status = "ダウンロード完了（webm音声のため共有から保存してください）"
            } else {
                status = "ダウンロード完了"
            }
            resultIsAudio = opt.audioOnly
            resultFile = final
            savedNote = ""
        } catch {
            let msg = error.localizedDescription
            if msg.contains("403"), triedClients.count < Innertube.totalClients {
                // 403はクライアント方式との相性が原因のことが多いので、別の方式で取り直す
                status = "方式 \(v.clientName) では403でした。別の方式で取り直します…"
                isError = false
                isBusy = false
                progress = nil
                await doFetch()
                if let nv = info {
                    status = "方式 \(nv.clientName) で取り直しました。形式をもう一度選んでください"
                }
            } else {
                status = msg
                isError = true
            }
        }
    }

    private func registerResult() {
        guard let current = resultFile else { return }
        resultItem = library.add(title: info?.title ?? "video", file: current, isAudio: resultIsAudio)
        savedNote = "ライブラリに保存しました"
    }

    private func savePhotos(_ file: URL, audio: Bool) async {
        let (ok, detail) = audio ? await MediaTools.saveAudioToPhotos(file) : await MediaTools.saveToPhotos(file)
        if ok {
            savedNote = "写真アプリに保存しました"
        } else {
            savedNote = ""
            status = "写真への保存に失敗しました：\(detail)"
            isError = true
        }
    }
}
