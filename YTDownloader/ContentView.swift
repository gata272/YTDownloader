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

struct PlayTarget: Identifiable {
    let id = UUID()
    let url: URL
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
    @State private var playing: PlayTarget? = nil
    @State private var resultItem: LibraryItem? = nil
    @State private var libraryAlertPath: String? = nil

    private let downloader = DownloadManager()

    var body: some View {
        TabView {
            downloadTab
                .tabItem { Label("ダウンロード", systemImage: "arrow.down.circle") }
            libraryTab
                .tabItem { Label("ライブラリ", systemImage: "play.square.stack") }
        }
        .fullScreenCover(item: $playing) { target in
            PlayerView(url: target.url)
        }
    }

    // MARK: - ダウンロードタブ

    private var downloadTab: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(signedIn ? "状態：サインイン済み" : "状態：未サインイン")
                            .font(.footnote)
                        Spacer()
                        if signedIn {
                            Button("サインアウト", role: .destructive) {
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
                    Button {
                        showLogin = true
                    } label: {
                        Label("YouTubeにサインイン", systemImage: "person.crop.circle")
                    }
                    Toggle("サインインのCookieを取得に使う", isOn: $useCookies)
                } header: {
                    Text("サインイン（bot確認の回避）")
                } footer: {
                    Text("サインインはGoogleの公式ページ上で行います。パスワードがこのアプリに渡ることはありません。Cookieを使う設定にすると取得時にWebKitへアクセスします。「取得」でアプリが落ちる場合はOFFのまま使ってください。")
                }

                Section {
                    TextField("YouTubeのリンク", text: $urlText, prompt: Text("https://www.youtube.com/watch?v=…"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let s = UIPasteboard.general.string { urlText = s }
                    } label: {
                        Label("貼り付け", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await fetch() }
                    } label: {
                        Label("取得", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || urlText.isEmpty)
                } header: {
                    Text("YouTubeのリンク")
                }

                if let info {
                    Section("動画") {
                        Text(info.title)
                            .font(.headline)
                        LabeledContent("取得方式", value: info.clientName)
                            .font(.subheadline)
                        if !info.fetchLog.isEmpty {
                            Text(info.fetchLog)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("ダウンロード形式") {
                        ForEach(options) { opt in
                            Button {
                                Task { await runDownload(opt) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label)
                                            .foregroundStyle(.primary)
                                        Text(opt.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .disabled(isBusy)
                        }
                    }
                }

                if let progress {
                    Section("進捗") {
                        ProgressView(value: progress) {
                            Text("ダウンロード中… \(Int(progress * 100))%")
                                .font(.subheadline)
                        }
                    }
                }

                if let resultFile {
                    Section("保存先") {
                        if let resultItem {
                            Button {
                                play(item: resultItem)
                            } label: {
                                Label("アプリ内で再生", systemImage: "play.circle")
                            }
                            Label("ライブラリに保存済み", systemImage: "checkmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                registerResult()
                            } label: {
                                Label("アプリ内に保存（ライブラリ）", systemImage: "square.and.arrow.down")
                            }
                        }
                        Button {
                            Task { await savePhotos(resultFile, audio: resultIsAudio) }
                        } label: {
                            Label(resultIsAudio ? "写真アプリに保存（音声）" : "写真アプリに保存", systemImage: "photo")
                        }
                        ShareLink(item: resultFile) {
                            Label("共有（ファイルに保存など）", systemImage: "square.and.arrow.up")
                        }
                        if !savedNote.isEmpty {
                            Text(savedNote)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                if !status.isEmpty {
                    Section("状態") {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .primary)
                    }
                }
            }
            .navigationTitle("YTDownloader")
            .sheet(isPresented: $showLogin, onDismiss: {
                Task { signedIn = await SessionManager.isSignedIn() }
            }) {
                WebLoginView { showLogin = false }
            }
        }
    }

    // MARK: - ライブラリタブ

    private var libraryTab: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView {
                        Label("ライブラリは空です", systemImage: "play.square.stack")
                    } description: {
                        Text("ダウンロードした動画を「アプリ内に保存」すると、ここに表示されます。")
                    }
                } else {
                    List {
                        ForEach(library.items) { item in
                            Button {
                                play(item: item)
                            } label: {
                                HStack(spacing: 12) {
                                    ThumbnailView(item: item, store: library)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                        Text("\(item.isAudio ? "音声" : "動画") ・ \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) ・ \(item.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    library.remove(item)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await saveLibraryItemToPhotos(item) }
                                } label: {
                                    Label("写真へ", systemImage: "photo")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("ライブラリ")
            .alert("ファイルが見つかりません", isPresented: Binding(
                get: { libraryAlertPath != nil },
                set: { if !$0 { libraryAlertPath = nil } }
            )) {
                Button("OK", role: .cancel) { libraryAlertPath = nil }
            } message: {
                Text("保存場所を探しましたが見つかりませんでした。\n\(libraryAlertPath ?? "")")
            }
        }
    }

    // MARK: - 再生

    private func play(item: LibraryItem) {
        if let url = library.resolve(item) {
            playing = PlayTarget(url: url)
        } else {
            libraryAlertPath = item.absolutePath
        }
    }

    private func saveLibraryItemToPhotos(_ item: LibraryItem) async {
        if let url = library.resolve(item) {
            await savePhotos(url, audio: item.isAudio)
        } else {
            libraryAlertPath = item.absolutePath
        }
    }

    // MARK: - 取得

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
           let bestA = v.audios.first(where: { $0.audioIsMP4Friendly }) {
            out.append(DownloadOption(label: "\(bestV.qualityLabel) 動画（高画質）", detail: "映像+音声を結合 / mp4",
                                      video: bestV, audio: bestA, audioOnly: false))
        }
        if let a = v.audios.first(where: { $0.audioIsMP4Friendly }) ?? v.audios.first {
            let ext = a.mimeType.contains("mp4") ? "m4a" : "webm"
            out.append(DownloadOption(label: "音声のみ", detail: "\(ext) / \(a.bitrate / 1000)kbps",
                                      video: a, audio: nil, audioOnly: true))
        }
        return out
    }

    // MARK: - ダウンロード

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

    // MARK: - 保存

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
