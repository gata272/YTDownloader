import Foundation

struct YTFormat {
    let itag: Int
    let mimeType: String
    let url: String
    let qualityLabel: String
    let height: Int
    let bitrate: Int
    let isAudio: Bool
    let isMuxed: Bool

    var codecIsMP4Friendly: Bool {
        mimeType.contains("avc1") || mimeType.contains("mp4")
    }
}

struct VideoInfo {
    let title: String
    let muxed: [YTFormat]          // 映像+音声入り単一ファイル
    let videos: [YTFormat]         // 映像のみ
    let audios: [YTFormat]         // 音声のみ
    let clientName: String
    let userAgent: String
}

struct YTError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ClientProfile {
    let name: String
    let clientNameHeader: String   // X-YouTube-Client-Name 数値ID
    let apiKey: String
    let userAgent: String
    let client: [String: Any]
}

enum Innertube {
    static func extractVideoID(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 11, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return s
        }
        let patterns = [#"v=([A-Za-z0-9_-]{11})"#, #"youtu\.be/([A-Za-z0-9_-]{11})"#,
                        #"shorts/([A-Za-z0-9_-]{11})"#, #"live/([A-Za-z0-9_-]{11})"#,
                        #"embed/([A-Za-z0-9_-]{11})"#, #"music\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                return String(s[r])
            }
        }
        return nil
    }

    private static let clients: [ClientProfile] = [
        ClientProfile(
            name: "ANDROID_VR", clientNameHeader: "28",
            apiKey: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            client: ["clientName": "ANDROID_VR", "clientVersion": "1.65.10",
                     "deviceMake": "Oculus", "deviceModel": "Quest 3",
                     "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L",
                     "userAgent": "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"]),
        ClientProfile(
            name: "IOS", clientNameHeader: "5",
            apiKey: "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_1 like Mac OS X;)",
            client: ["clientName": "IOS", "clientVersion": "20.10.4",
                     "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                     "osName": "iPhone", "osVersion": "18.3.1.22D72",
                     "userAgent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_1 like Mac OS X;)"]),
        ClientProfile(
            name: "TVHTML5", clientNameHeader: "7",
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
            userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
            client: ["clientName": "TVHTML5", "clientVersion": "7.20250219.16.00",
                     "userAgent": "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version"]),
        ClientProfile(
            name: "ANDROID", clientNameHeader: "3",
            apiKey: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
            userAgent: "com.google.android.youtube/19.47.53 (Linux; U; Android 14) gzip",
            client: ["clientName": "ANDROID", "clientVersion": "19.47.53",
                     "androidSdkVersion": 34, "osName": "Android", "osVersion": "14",
                     "userAgent": "com.google.android.youtube/19.47.53 (Linux; U; Android 14) gzip"]),
    ]

    static func fetchInfo(videoID: String) async throws -> VideoInfo {
        var lastError = "取得できませんでした"
        for profile in clients {
            do {
                if let info = try await fetchInfo(videoID: videoID, profile: profile) {
                    return info
                }
            } catch let e as YTError {
                lastError = e.message
                continue
            } catch {
                lastError = error.localizedDescription
                continue
            }
        }
        throw YTError(message: "全ての方式で取得に失敗しました（\(lastError)）。動画によっては制限されています。")
    }

    private static func fetchInfo(videoID: String, profile: ClientProfile) async throws -> VideoInfo? {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?key=\(profile.apiKey)&prettyPrint=false") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(profile.clientNameHeader, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(profile.client["clientVersion"] as? String, forHTTPHeaderField: "X-YouTube-Client-Version")
        let body: [String: Any] = [
            "context": ["client": profile.client],
            "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": ["vis": 0, "splay": false, "lactMilliseconds": "-1"]],
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let ps = json["playabilityStatus"] as? [String: Any],
           let status = ps["status"] as? String, status != "OK" {
            let reason = ps["reason"] as? String ?? status
            throw YTError(message: "\(profile.name): 再生不可 (\(reason))")
        }
        guard let sd = json["streamingData"] as? [String: Any] else { return nil }
        let title = (json["videoDetails"] as? [String: Any])?["title"] as? String ?? "video"

        func parse(_ list: [[String: Any]]?, muxed: Bool) -> [YTFormat] {
            guard let list else { return [] }
            return list.compactMap { f -> YTFormat? in
                guard let direct = f["url"] as? String else { return nil } // 署名付きURLのみの場合は使えない
                let mime = f["mimeType"] as? String ?? ""
                let height = f["height"] as? Int ?? 0
                return YTFormat(
                    itag: f["itag"] as? Int ?? 0,
                    mimeType: mime,
                    url: direct,
                    qualityLabel: f["qualityLabel"] as? String ?? (mime.hasPrefix("audio") ? "音声" : "\(height)p"),
                    height: height,
                    bitrate: f["bitrate"] as? Int ?? 0,
                    isAudio: mime.hasPrefix("audio"),
                    isMuxed: muxed)
            }
        }

        let muxed = parse(sd["formats"] as? [[String: Any]], muxed: true)
        let adaptive = parse(sd["adaptiveFormats"] as? [[String: Any]], muxed: false)
        let videos = adaptive.filter { !$0.isAudio }.sorted { $0.height > $1.height }
        let audios = adaptive.filter { $0.isAudio }.sorted { $0.bitrate > $1.bitrate }
        guard !muxed.isEmpty || (!videos.isEmpty && !audios.isEmpty) || !audios.isEmpty else { return nil }
        return VideoInfo(title: title,
                         muxed: muxed.sorted { $0.height > $1.height },
                         videos: videos, audios: audios,
                         clientName: profile.name, userAgent: profile.userAgent)
    }
}
