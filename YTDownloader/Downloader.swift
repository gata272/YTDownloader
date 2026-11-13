import Foundation
import AVFoundation
import Photos

final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double) -> Void)?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(urlString: String, userAgent: String, clientNameHeader: String = "", clientVersion: String = "", progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else { throw YTError(message: "URLが不正です") }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        if !clientNameHeader.isEmpty {
            req.setValue(clientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        }
        if !clientVersion.isEmpty {
            req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        }
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
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: YTError(message: "ダウンロード失敗 (HTTP \(http.statusCode))"))
            continuation = nil
            return
        }
        let dest = FileManager.default.temporaryDirectory
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

        let out = FileManager.default.temporaryDirectory
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

    static func saveToPhotos(_ file: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
            }
            return true
        } catch {
            return false
        }
    }

    static func saveAudioToPhotos(_ file: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .audio, fileURL: file, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}
