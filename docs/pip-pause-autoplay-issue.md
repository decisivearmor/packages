# PiP一時停止後の自動再生問題 - 修正状況レポート

## 問題の概要
PiPモードで動画を一時停止した後、画面をロック**した瞬間**に動画が自動再生されてしまう問題。
（ロック解除時ではなく、ロック実行時に再生が開始される）

## 現在の状況（2025-07-02 修正作業後）
- **問題**: 解決済み（テスト待ち）
- **原因特定**: 完了
- **修正試行**: 成功
- **最新コミット**: （コミット後に更新）

## 問題の根本原因分析

### 1. 自動再生ロジックの存在
以前の「動画が勝手に停止する問題」を解決するために以下の自動再生再開処理が実装されている：

#### 自動再生が発動する箇所（4箇所）
1. **`applicationWillResignActive`** (FVPVideoPlayer.m:1399)
2. **HLSバックグラウンド処理** (FVPVideoPlayer.m:1668) 
3. **バックグラウンド移行完了時** (FVPVideoPlayer.m:1683)
4. **1秒間隔の監視タイマー** (FVPVideoPlayer.m:1826) ← 最も影響大

#### 自動再生の条件
```objective-c
if (_isPlaying && _player.rate == 0 && !_userExplicitlyPaused && !_deviceIsLocked) {
    [_player play];  // 自動再生実行
}
```

### 2. フラグ管理の問題
- PiP一時停止時: `_userExplicitlyPaused = YES` ✅
- 自動再生実行後: AVPlayerのrate変化により`_userExplicitlyPaused = NO`に**自動リセット** ❌
- 結果: 後続の自動再生ロジックもブロックされない

### 3. デバイスロック検知の問題
- `protectedDataWillBecomeUnavailable`がPiP時に発火しない場合がある
- `applicationDidEnterBackground`での補完検知を追加済み

## 実施した修正内容

### 修正1: Remote Command Centerの重複防止
**コミット**: 99bebedf4, 13683007a
- ヘッダーファイルにmissingメソッド宣言を追加
- unrecognized selectorクラッシュを修正

### 修正2: デバイスロック検知の強化  
**コミット**: 7f24311ad
- `togglePlayPauseCommand`ハンドラーにデバイスロック検知を追加
- `applicationDidEnterBackground`でのロック検知を強化
- playメソッドに詳細トレーシングログを追加

### 修正3: フラグリセット防止（根本原因への対処）
**コミット**: e68a105a4
- デバイスロック時のAVPlayer rate変化による`_userExplicitlyPaused`自動リセットを防止
```objective-c
// デバイスロック時は自動再生によるフラグリセットを防ぐ
if (!_deviceIsLocked) {
    _userExplicitlyPaused = NO;
} else {
    NSLog(@"🔒 Rate changed while device locked - NOT resetting user pause flag");
}
```

## 確認されている現象

### 修正前のログパターン
```
⏸️ [VideoPlayer] User paused from PiP controls
🔒 [VideoPlayer] Device locking - player is currently paused
▶️ [VideoPlayer] User resumed from PiP controls  # ロック実行時に発生
▶️ [VideoPlayer] User resumed from PiP controls  # 重複発生
```

**重要**: 上記の再生開始は画面ロック解除時ではなく、**ロック実行時**に発生している

### 期待される修正後の動作
- PiP一時停止後の画面ロック**実行時**に再生が開始されない
- 「User resumed from PiP controls」の重複ログが解消される
- 画面ロック中も一時停止状態が維持される

## 実施した最終修正（2025-07-02）

### 修正内容

#### 1. PiP一時停止専用フラグの導入
- 新しいインスタンス変数 `_pausedFromPiP` を追加
- PiPコントロールから一時停止された場合にこのフラグをYESに設定
- PiPコントロールから明示的に再生された場合のみこのフラグをNOにリセット

#### 2. AVPlayer rate変化監視の改善
- PiPモード中のrate変化があった際、自動再生による変化かどうかを判定
- `_pausedFromPiP`フラグがセットされている場合、`_userExplicitlyPaused`のリセットをスキップ

#### 3. Remote Command Centerの修正
- playCommandハンドラーとtogglePlayPauseCommandハンドラーで、PiPから再生が実行された時に`_pausedFromPiP`フラグをNOにリセット

#### 4. すべての自動再生ロジックにチェック追加
- applicationWillResignActive
- 1秒間隔の監視タイマー
- HLSバックグラウンド処理
- バックグラウンド移行完了時

すべての箇所で`!_pausedFromPiP`条件を追加し、PiPから一時停止された場合は自動再生をスキップ

#### 5. pauseメソッドの改善
- PiPモード中の一時停止を検出して`_pausedFromPiP`フラグをセット

### 期待される改善結果
- PiPコントロールから一時停止後、画面ロック時に自動再生されない
- PiP一時停止状態がユーザーが明示的に再生ボタンを押すまで維持される
- デバイスロック中も一時停止状態が保持される

### テスト手順
1. 動画をPiPモードで再生
2. PiPコントロールから一時停止
3. デバイスをロック
4. 自動再生が発生しないことを確認
5. ロック解除後、PiPコントロールから再生ボタンを押して再生が開始されることを確認

## 技術的メモ

### 関連する重要なフラグ
- `_userExplicitlyPaused`: ユーザーの明示的な一時停止を記録
- `_deviceIsLocked`: デバイスのロック状態
- `_isInPictureInPicture`: PiPモード状態
- `_isPlaying`: 再生状態の管理

### デバッグ用ログキーワード
- `🎬 [VideoPlayer] PLAY COMMAND EXECUTED`
- `⏸️ [VideoPlayer] User paused from PiP controls`
- `🔒 [VideoPlayer] Device locking`
- `▶️ [VideoPlayer] User resumed from PiP controls`

## 次回作業時の手順
1. 最新の修正での動作確認とログ収集
2. まだ問題が残る場合は1秒間隔監視タイマーの修正
3. PiP中のrate変化監視ロジックの見直し
4. 完全解決後のテストケース実行

## 関連ファイル
- `/packages/video_player/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPVideoPlayer.m`
- `/Users/decisivearmor/work/flutter/dlab_flutter/pubspec.yaml` (参照先: e68a105a4)