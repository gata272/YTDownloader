# YTダウンローダ (YTDownloader)

YouTubeリンクを貼ると、yt-dlp が使っているのと同じ「innertube API を複数クライアント
（ANDROID_VR / IOS / TVHTML5 / ANDROID）で叩いて直接リンクを取る」方式で
動画・音声を取得し、写真アプリやファイルに保存する SwiftUI アプリ。

- 720p以下は単一ファイル（mp4）をそのまま保存
- 高画質は映像+音声をダウンロードして AVFoundation で結合
- 音声のみ（m4a）も可

## 限界
- 署名付きURL（signatureCipher）しか返らない動画、POトークン必須の動画は取得できない
- 取得可否は動画ごとに変わる（YouTube側の仕様変更の影響を受ける）

## ビルド
GitHub Actions で未署名 IPA を生成し、LiveContainer に入れて使う。
リポジトリへのアップロードは GHアップローダ（自作）が使えればZIPごと一括で可能。
