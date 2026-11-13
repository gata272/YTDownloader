import SwiftUI
import WebKit

/// アプリ内ブラウザ（WKWebView）で YouTube にサインインし、
/// そのセッション Cookie を取得リクエストに流用するための仕組み。
/// Cookie の実体は WebView のデータストアにだけ保存され、アプリ側は毎回そこから読み出す。
enum SessionManager {
    static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
    }

    /// youtube.com 向けの Cookie ヘッダ文字列（なければ空）
    static func cookieHeader() async -> String {
        let cookies = await allCookies()
        let ys = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        return ys.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// サインイン済みらしい Cookie があるか
    static func isSignedIn() async -> Bool {
        let cookies = await allCookies()
        return cookies.contains {
            $0.domain.hasSuffix("youtube.com") &&
            ($0.name == "SID" || $0.name == "SAPISID" || $0.name == "__Secure-3PSID" || $0.name == "LOGIN_INFO")
        }
    }

    /// サインアウト：WebView の全データを消す
    static func clearAll() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.fetchDataRecords(ofTypes: types) { records in
                store.removeData(ofTypes: types, for: records) {
                    cont.resume()
                }
            }
        }
    }
}

struct WebLoginView: View {
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            WebView()
                .navigationTitle("YouTube サインイン")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { onClose() }
                    }
                }
        }
    }
}

struct WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        // 組み込みブラウザ判定でログインを弾かれにくくするため Safari の UA に寄せる
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"
        if let url = URL(string: "https://www.youtube.com/") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
