# 再初期化なしでPiPモードを切り替える方法

## 概要

VideoPlayerControllerを再初期化することなく、再生中にPiPモードの動作を切り替える方法について説明します。

## 実装方法

### 1. 即座にPiPモードから自動PiPモードへの切り替え

```dart
// 現在: setPictureInPictureEnabled(true)で即座にPiPに入っている状態
// 切り替え: ホームボタンでのみPiPに入るようにする

// まず現在のPiP設定をクリア
await controller.clearPictureInPictureSettings();

// 自動PiPモードを有効化
await controller.setAutoPictureInPictureEnabled(true);
```

### 2. 自動PiPモードから即座にPiPモードへの切り替え

```dart
// 現在: setAutoPictureInPictureEnabled(true)でホームボタン時のみPiP
// 切り替え: 即座にPiPに入るようにする

// PiP設定をクリア
await controller.clearPictureInPictureSettings();

// 通常のPiPモードを有効化（即座にPiPに入る）
await controller.setPictureInPictureEnabled(true);
```

### 3. PiPを完全に無効化

```dart
// すべてのPiP設定をクリア
await controller.clearPictureInPictureSettings();

// または明示的に無効化
await controller.setPictureInPictureEnabled(false);
await controller.setAutoPictureInPictureEnabled(false);
```

## dlab_flutterでの実装例

```dart
// unified_player_provider.dart

class UnifiedPlayerNotifier extends StateNotifier<UnifiedPlayerState> {
  // 現在のPiPモード
  PiPMode _currentPiPMode = PiPMode.disabled;
  
  // PiPモードを動的に切り替える
  Future<void> switchPiPMode(PiPMode mode) async {
    if (_videoPlayerController == null || !Platform.isAndroid) return;
    
    try {
      // 現在の設定をクリア
      await _videoPlayerController!.clearPictureInPictureSettings();
      
      switch (mode) {
        case PiPMode.immediate:
          // 即座にPiPモード
          await _videoPlayerController!.setPictureInPictureEnabled(true);
          break;
          
        case PiPMode.onHomeButton:
          // ホームボタンでPiP
          await _videoPlayerController!.setAutoPictureInPictureEnabled(true);
          break;
          
        case PiPMode.disabled:
          // PiP無効
          // clearPictureInPictureSettings()だけで十分
          break;
      }
      
      _currentPiPMode = mode;
      Logger().i('PiPモード切り替え完了: $mode');
      
    } catch (e) {
      Logger().e('PiPモード切り替えエラー: $e');
    }
  }
}

// PiPモードの定義
enum PiPMode {
  immediate,    // 即座にPiP
  onHomeButton, // ホームボタンでPiP
  disabled,     // PiP無効
}
```

## UIでの実装例

```dart
// PiPモード選択ダイアログ
class PiPModeSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentMode = ref.watch(pipModeProvider);
    
    return SimpleDialog(
      title: Text('PiPモード設定'),
      children: [
        RadioListTile<PiPMode>(
          title: Text('即座にPiP'),
          subtitle: Text('ボタンを押すとすぐに小窓表示'),
          value: PiPMode.immediate,
          groupValue: currentMode,
          onChanged: (mode) async {
            if (mode != null) {
              Navigator.pop(context);
              await ref.read(unifiedPlayerProvider.notifier)
                  .switchPiPMode(mode);
              ref.read(pipModeProvider.notifier).state = mode;
            }
          },
        ),
        RadioListTile<PiPMode>(
          title: Text('ホームボタンでPiP'),
          subtitle: Text('アプリを離れる時に小窓表示'),
          value: PiPMode.onHomeButton,
          groupValue: currentMode,
          onChanged: (mode) async {
            if (mode != null) {
              Navigator.pop(context);
              await ref.read(unifiedPlayerProvider.notifier)
                  .switchPiPMode(mode);
              ref.read(pipModeProvider.notifier).state = mode;
            }
          },
        ),
        RadioListTile<PiPMode>(
          title: Text('PiP無効'),
          subtitle: Text('小窓表示しない'),
          value: PiPMode.disabled,
          groupValue: currentMode,
          onChanged: (mode) async {
            if (mode != null) {
              Navigator.pop(context);
              await ref.read(unifiedPlayerProvider.notifier)
                  .switchPiPMode(mode);
              ref.read(pipModeProvider.notifier).state = mode;
            }
          },
        ),
      ],
    );
  }
}
```

## 重要なポイント

1. **clearPictureInPictureSettings()の使用**
   - モードを切り替える前に必ず呼び出す
   - これにより前の設定がクリアされ、新しい設定が正しく適用される

2. **エラーハンドリング**
   - Android専用の機能なので、他のプラットフォームでは何も起こらない
   - エラーが発生してもアプリがクラッシュしないようにtry-catchで保護

3. **状態管理**
   - 現在のPiPモードを保持して、UIに反映させる
   - SharedPreferencesなどで永続化することも検討

4. **ユーザー体験**
   - モード切り替え時にフィードバックを表示
   - 現在のモードが分かるようにUIを工夫

## トラブルシューティング

### 設定が反映されない場合
- `clearPictureInPictureSettings()`が正しく呼ばれているか確認
- ログで`clearPiPSettings`が実行されているか確認

### PiPモードに入らない場合
- AndroidManifestでPiPが有効になっているか確認
- デバイスがAndroid 8.0以上か確認