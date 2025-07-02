# dlab_flutter PiP自動モード統合ガイド

## 問題

`setAutoPictureInPictureEnabled`を呼び出しても、VideoPlayerControllerを再初期化するまで設定が反映されない。

## 解決策

### 1. unified_player_provider.dartに設定を追加

```dart
// unified_player_provider.dart

class UnifiedPlayerNotifier extends StateNotifier<UnifiedPlayerState> {
  // PiP設定フラグ
  bool _useImmediatePiP = false; // true: 即座にPiP, false: ホームボタンでPiP
  
  // VideoPlayerController初期化後のPiP設定
  Future<void> _configurePiPAfterInitialization() async {
    if (_videoPlayerController == null || !Platform.isAndroid) return;
    
    try {
      if (_useImmediatePiP) {
        // 即座にPiPモードに入る設定
        await _videoPlayerController!.setPictureInPictureEnabled(true);
      } else {
        // ホームボタン押下時のみPiPモードに入る設定
        await _videoPlayerController!.setAutoPictureInPictureEnabled(true);
      }
      Logger().i('PiP設定完了: immediate=$_useImmediatePiP');
    } catch (e) {
      Logger().e('PiP設定エラー: $e');
    }
  }
  
  // _initializeVideoPlayerメソッドを修正
  Future<void> _initializeVideoPlayer(String url) async {
    // ... 既存の初期化処理 ...
    
    try {
      // VideoPlayerControllerを初期化
      await _videoPlayerController!.initialize();
      Logger().i('VideoPlayerController初期化完了 - 動画再生準備完了');
      
      // PiP設定を適用
      await _configurePiPAfterInitialization();
      
      // ... 残りの処理 ...
    } catch (e) {
      // ... エラー処理 ...
    }
  }
  
  // PiPモード設定を変更するメソッド
  Future<void> setPiPMode({required bool immediate}) async {
    _useImmediatePiP = immediate;
    
    // 既に初期化済みのコントローラーがある場合は設定を適用
    if (_videoPlayerController != null && Platform.isAndroid) {
      await _configurePiPAfterInitialization();
    }
  }
}
```

### 2. UIでの使用例

```dart
// PiP設定画面
class PiPSettingsScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text('PiP設定')),
      body: ListView(
        children: [
          RadioListTile<bool>(
            title: Text('即座にPiPモードに入る'),
            subtitle: Text('PiPボタンを押すとすぐに小窓表示'),
            value: true,
            groupValue: ref.watch(pipModeProvider),
            onChanged: (value) async {
              if (value != null) {
                ref.read(pipModeProvider.notifier).state = value;
                await ref.read(unifiedPlayerProvider.notifier)
                    .setPiPMode(immediate: value);
              }
            },
          ),
          RadioListTile<bool>(
            title: Text('ホームボタンでPiPモードに入る'),
            subtitle: Text('アプリを離れる時のみ小窓表示'),
            value: false,
            groupValue: ref.watch(pipModeProvider),
            onChanged: (value) async {
              if (value != null) {
                ref.read(pipModeProvider.notifier).state = value;
                await ref.read(unifiedPlayerProvider.notifier)
                    .setPiPMode(immediate: value);
              }
            },
          ),
        ],
      ),
    );
  }
}

// PiPモード設定を保持するProvider
final pipModeProvider = StateProvider<bool>((ref) => false);
```

### 3. プレイヤー画面でのPiPボタン

```dart
// プレイヤーコントロールバー
class PlayerControlBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isImmediatePiP = ref.watch(pipModeProvider);
    
    return Row(
      children: [
        // ... 他のコントロール ...
        
        if (Platform.isAndroid)
          IconButton(
            icon: Icon(Icons.picture_in_picture),
            onPressed: () async {
              if (isImmediatePiP) {
                // 即座にPiPモードに入る
                await ref.read(unifiedPlayerProvider.notifier)
                    .togglePictureInPictureMode();
              } else {
                // 設定画面へ誘導
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('ホームボタンを押すとPiPモードになります'),
                    action: SnackBarAction(
                      label: '設定変更',
                      onPressed: () {
                        Navigator.pushNamed(context, '/pip-settings');
                      },
                    ),
                  ),
                );
              }
            },
          ),
      ],
    );
  }
}
```

## 重要な注意点

1. **初期化時の設定**
   - VideoPlayerControllerの初期化完了後に必ずPiP設定を適用する
   - 設定変更後は既存のコントローラーにも反映させる

2. **状態管理**
   - PiPモード設定は永続化することを推奨（SharedPreferences等）
   - アプリ起動時に保存された設定を読み込む

3. **エラーハンドリング**
   - PiP設定が失敗してもアプリの動作に影響しないようにする
   - ログを適切に出力してデバッグを容易にする

## トラブルシューティング

### 設定が反映されない場合

1. VideoPlayerControllerが初期化済みか確認
2. Androidデバイスか確認
3. ログでエラーが出ていないか確認

### PiPが起動しない場合

1. AndroidManifestでPiPが有効か確認
2. デバイスがPiPをサポートしているか確認（Android 8.0以上）
3. アプリの権限設定を確認