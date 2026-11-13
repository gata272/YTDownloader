import Foundation
import AVFoundation
import Photos

final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double) -> Void)?
    private var lastResponse: HTTPURLResponse?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func makeRequest(urlString: String, userAgent: String, clientNameHeader: String, clientVersion: String, visitorData: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw YTError(message: "URLが不正です") }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if !clientNameHeader.isEmpty {
            req.setValue(clientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        }
        if !clientVersion.isEmpty {
            req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        }
        if !visitorData.isEmpty {
            req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        return req
    }

    func download(urlString: String, userAgent: String, clientNameHeader: String = "", clientVersion: String = "", visitorData: String = "", progress: @escaping (Double) -> Void) async throws -> URL {
        let baseReq = try makeRequest(urlString: urlString, userAgent: userAgent, clientNameHeader: clientNameHeader, clientVersion: clientVersion, visitorData: visitorData)

        // まず Range（bytes=0-0）で様子を見る。
        // - 206 が返れば総サイズが分かるので、大きければ分割ダウンロードに切り替える
        //   （googlevideo は1接続を持続的に絞るため、分割すると各区間の初速が使えて速い）
        // - 200 が返れば Range 非対応で、その応答自体が全量ダウンロード済み
        // - 403 は performDownload 側で YTError になり、方式の切り替えに回る
        var probeReq = baseReq
        probeReq.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let probeFile = try await performDownload(probeReq) { _ in }
        if let http = lastResponse, http.statusCode == 206, let total = Self.parseTotalSize(http) {
            try? FileManager.default.removeItem(at: probeFile)
            if total > 8 * 1024 * 1024 {
                return try await downloadChunked(baseReq, total: total, progress: progress)
            }
            return try await performDownload(baseReq, progress: progress)
        }
        progress(1.0)
        return probeFile
    }

    private static func parseTotalSize(_ http: HTTPURLResponse) -> Int64? {
        guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = cr.lastIndex(of: "/") else { return nil }
        return Int64(cr[cr.index(after: slash)...])
    }

    private func downloadChunked(_ baseReq: URLRequest, total: Int64, progress: @escaping (Double) -> Void) async throws -> URL {
        let chunkSize: Int64 = 8 * 1024 * 1024
        let out = DownloadManager.documentsDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: out.path) else {
            throw YTError(message: "保存先ファイルを作成できませんでした")
        }
        defer { handle.closeFile() }
        var done: Int64 = 0
        while done < total {
            let end = min(done + chunkSize, total) - 1
            var req = baseReq
            req.setValue("bytes=\(done)-\(end)", forHTTPHeaderField: "Range")
            let part = try await performDownload(req) { _ in }
            let data = try Data(contentsOf: part)
            handle.seekToEndOfFile()
            handle.write(data)
            try? FileManager.default.removeItem(at: part)
            done = end + 1
            progress(Double(done) / Double(total))
        }
        return out
    }

    private func performDownload(_ req: URLRequest, progress: @escaping (Double) -> Void) async throws -> URL {
        lastResponse = nil
        progressHandler = progress
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse {
            lastResponse = http
            if !(200...299).contains(http.statusCode) {
                continuation?.resume(throwing: YTError(message: "ダウンロード失敗 (HTTP \(http.statusCode))"))
                continuation = nil
                return
            }
        }
        // 一時フォルダはOSに消されることがあるため、安定した Documents に置く
        let dest = DownloadManager.documentsDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

enum MediaTools {
    /// 映像ファイルと音声ファイルを1つのmp4に結合する
    static func mux(video: URL, audio: URL) async throws -> URL {
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)
        let comp = AVMutableComposition()
        guard let vSrc = try await vAsset.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aSrc = try await aAsset.loadTracks(withMediaType: .audio).first,
              let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YTError(message: "結合の準備に失敗しました")
        }
        let vDur = try await vAsset.load(.duration)
        let aDur = try await aAsset.load(.duration)
        try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        try aDst.insertTimeRange(CMTimeRange(start: .zero, duration: min(aDur, vDur)), of: aSrc, at: .zero)

        let out = DownloadManager.documentsDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw YTError(message: "書き出しセッションを作れませんでした")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else {
            throw YTError(message: "結合に失敗しました: \(export.error?.localizedDescription ?? "不明")")
        }
        return out
    }

    static func saveToPhotos(_ file: URL) async -> (Bool, String) {
        await saveToPhotos(file, resourceType: .video)
    }

    static func saveAudioToPhotos(_ file: URL) async -> (Bool, String) {
        await saveToPhotos(file, resourceType: .audio)
    }

    /// 失敗時は「認可状態」と「実際のエラー」をそのまま返す（原因の切り分け用）
    private static func saveToPhotos(_ file: URL, resourceType: PHAssetResourceType) async -> (Bool, String) {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return (false, "写真への追加が許可されていません（認可状態: \(String(describing: status))）。設定アプリでこのアプリの写真アクセスを確認してください")
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            return (false, "保存するファイルが見つかりませんでした。ダウンロードからやり直してください")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: resourceType, fileURL: file, options: nil)
            }
            return (true, "")
        } catch {
            let ns = error as NSError
            return (false, "\(error.localizedDescription) [\(ns.domain) \(ns.code)]")
        }
    }
}
