# CLAUDE.md

このファイルは、このリポジトリのコードを扱う際のClaude Code (claude.ai/code) へのガイダンスを提供します。

## リポジトリ概要

これはFlutterの公式パッケージリポジトリで、ファーストパーティのFlutterプラグインが含まれています。フェデレーテッドプラグインを使用したモノレポ構造になっています。

### 主要ディレクトリ
- `packages/`: ファーストパーティのFlutterパッケージ
- `third_party/packages/`: Flutterチームがメンテナンスしているが、元々はサードパーティが作成したパッケージ
- `script/tool/`: 開発タスク用のカスタムFlutterプラグインツール

## 開発コマンド

すべての開発タスクはカスタムFlutterプラグインツールを使用します。まずツールをセットアップします：
```bash
cd script/tool && dart pub get && cd ../../
```

その後、これらのコマンドを使用します（`package_name`を実際のパッケージ名に置き換えてください）：
```bash
# コードのフォーマット
dart run script/tool/bin/flutter_plugin_tools.dart format --packages package_name

# コードの解析
dart run script/tool/bin/flutter_plugin_tools.dart analyze --packages package_name

# テストの実行
dart run script/tool/bin/flutter_plugin_tools.dart test --packages package_name

# サンプルアプリのビルド
dart run script/tool/bin/flutter_plugin_tools.dart build-examples --apk --packages package_name

# 統合テストの実行
dart run script/tool/bin/flutter_plugin_tools.dart drive-examples --android --packages package_name

# ネイティブテストの実行
dart run script/tool/bin/flutter_plugin_tools.dart native-test --ios --android --packages package_name

# README内のコード抜粋の更新
dart run script/tool/bin/flutter_plugin_tools.dart update-excerpts --packages package_name

# バージョンとCHANGELOGの更新
dart run script/tool/bin/flutter_plugin_tools.dart update-release-info --packages package_name
```

## アーキテクチャパターン

### フェデレーテッドプラグイン構造
ほとんどのプラグインは以下のパターンに従います：
1. **プラットフォームインターフェースパッケージ** (例: `video_player_platform_interface/`) - APIコントラクトを定義
2. **プラットフォーム実装** (例: `video_player_android/`, `video_player_avfoundation/`) - プラットフォーム固有のコード
3. **メインパッケージ** (例: `video_player/`) - すべてを統合し、APIをエクスポート

### コード規約
- `analysis_options.yaml`で定義された厳格な解析を伴う`flutter_lints`を使用
- C++コードはclangバージョン15.0.0でフォーマットする必要があります
- すべてのPRにはテスト（ユニット、ネイティブ、または統合）が必要です
- READMEのコードスニペットはコード抜粋で管理されます

## 重要な開発メモ
- Issueはこのリポジトリではなく、メインのFlutterリポジトリに報告してください
- PRは自動的にコードオーナーに割り当てられます（CODEOWNERSファイルを参照）
- リポジトリには広範なCI/CD自動化があります
- プラットフォーム固有のコードを変更する際は、すべてのサポートされているプラットフォームで互換性があることを確認してください
- 統合テストは`integration_test`パッケージパターンを使用します

## 重要：ローカル開発専用
- これはFlutterパッケージリポジトリのローカルフォーク/クローンです
- ここで行った変更はローカル使用専用です
- アップストリームのFlutterリポジトリにプルリクエストを作成しないでください
- すべての変更はローカルまたはプライベートフォークで管理してください

## video_playerフォーク用のプロジェクト固有の指示

### スコープの制限
- `video_player`パッケージとそのサブパッケージ内のファイル**のみ**を変更してください
- このリポジトリの他のパッケージは編集**しないでください**
- iOS/macOSの機能強化のためにvideo_player_avfoundationに専念してください

### 現在の開発フォーカス
- iOS向けPicture-in-Picture (PiP)機能の実装
- バックグラウンド再生機能の強化
- 通知センター統合の改善
- 詳細なステータスは`docs/pip-implementation-progress.md`を参照してください

### バックグラウンドタスク要件
- PiPアクティベーションの**前に**通知センターが表示されている必要があります
- 永続的な通知表示のためのバックグラウンドタスク管理を実装
- バックグラウンドタスクのライフサイクルをビデオ再生状態と調整

### 開発ワークフロー
1. video_player関連のファイルのみに変更を加える
2. iOSデバイス/シミュレーターで徹底的にテストする
3. 説明的なメッセージで変更をコミットする
4. docsディレクトリに進捗を文書化する

## iOS/macOS開発メモ
- Appleフレームワーク定数には常に文字列リテラルを使用してください（例：AVURLAssetHTTPHeaderFieldsKeyではなく@"AVURLAssetHTTPHeaderFieldsKey"）
- これによりコンパイル時の「undeclared identifier」エラーを防ぎます
- 定数名を直接使用する前に必ず存在を確認してください
# 重要な指示のリマインダー
要求されたことのみを行い、それ以上でもそれ以下でもない。
目標を達成するために絶対に必要な場合を除き、ファイルを作成しない。
新しいファイルを作成するよりも、既存のファイルを編集することを常に優先する。
ドキュメントファイル（*.md）やREADMEファイルを積極的に作成しない。ユーザーから明示的に要求された場合のみドキュメントファイルを作成する。

## 言語設定
- ユーザーへの回答は必ず日本語で行ってください
- コード内のコメントは英語のままにしてください

## コード実装時の注意事項
- 関数を実装・変更する際は、必ずヘッダーファイル（.hファイル）の宣言と実装ファイル（.m/.mmファイル）の定義が一致していることを確認してください
- パラメータ名、型、戻り値の型がヘッダーと実装で完全に一致していることを確認してください
- メソッドシグネチャの不一致はコンパイルエラーの原因となるため、タスク完了前に必ず確認してください