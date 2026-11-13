# YTダウンローダ (YTDownloader) v1.2

YouTubeリンクを貼ると、yt-dlp が使っているのと同じ「innertube API を複数クライアント
（ANDROID_VR / IOS / TVHTML5 / ANDROID）で叩いて直接リンクを取る」方式で
動画・音声を取得し、写真アプリやファイルに保存する SwiftUI アプリ。

## v1.2 の追加
- アプリ内ブラウザ（WKWebView、Safari UA）で YouTube にサインインし、
  そのセッション Cookie を取得リクエストに付与する。
  「Sign in to confirm you're not a bot」対策（yt-dlp での定番解法と同じ）。
- ダウンロード時に 403 が出たら、未試行のクライアント方式で自動的に取り直す（v1.1）。
- Cookie の実体は WebView のデータストア内のみ。アプリは毎回そこから読み出す。

## 限界
- Google がアプリ内ブラウザでのサインインをブロックする場合がある
- 署名付きURL（signatureCipher）しか返らない動画、POトークン必須の動画は取得できない
- 取得可否は動画ごとに変わる（YouTube側の仕様変更の影響を受ける）
