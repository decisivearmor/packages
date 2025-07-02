# PiP自動モード使用ガイド

## 概要

`setPictureInPictureEnabled`と`setAutoPiPEnabled`の違いと使い方について説明します。

## メソッドの違い

### 1. setPictureInPictureEnabled（既存）
- **動作**: 即座にPiPモードに入る
- **用途**: すぐにPiPモードに切り替えたい場合

```dart
// 即座にPiPモードに入る
await controller.setPictureInPictureEnabled(true);
```

### 2. setAutoPiPEnabled（新規）
- **動作**: ホームボタン押下時のみPiPモードに入る
- **用途**: ユーザーがアプリを離れる時のみPiPを起動したい場合

```dart
import 'package:video_player/src/android_pip_helper.dart';

// ホームボタン押下時のみPiPモードに入る設定
await AndroidPiPHelper.setAutoPiPEnabled(
  controller.textureId,
  true,
);
```

## 実装例

### dlab_flutterでの使用例

```dart
// unified_player_provider.dartに追加
class UnifiedPlayerNotifier extends StateNotifier<UnifiedPlayerState> {
  bool _useAutoPiP = true; // デフォルトは自動PiP
  
  // PiPモードの設定
  Future<void> configurePiP({bool immediate = false}) async {
    if (_videoPlayerController == null || !Platform.isAndroid) return;
    
    try {
      if (immediate) {
        // 即座にPiPモードに入る（従来の動作）
        await _videoPlayerController!.setPictureInPictureEnabled(true);
      } else {
        // ホームボタン押下時のみPiPモードに入る
        await AndroidPiPHelper.setAutoPiPEnabled(
          _videoPlayerController!.textureId,
          true,
        );
      }
    } catch (e) {
      Logger().e('PiP設定エラー: $e');
    }
  }
  
  // PiPモードを無効化
  Future<void> disablePiP() async {
    if (_videoPlayerController == null || !Platform.isAndroid) return;
    
    try {
      // 両方の設定を無効化
      await _videoPlayerController!.setPictureInPictureEnabled(false);
      await AndroidPiPHelper.setAutoPiPEnabled(
        _videoPlayerController!.textureId,
        false,
      );
    } catch (e) {
      Logger().e('PiP無効化エラー: $e');
    }
  }
}
```

### UIでの実装例

```dart
// PiP設定ボタン
class PiPSettingsButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.picture_in_picture),
      onSelected: (value) async {
        final notifier = ref.read(unifiedPlayerProvider.notifier);
        
        switch (value) {
          case 'immediate':
            // 即座にPiPモードに入る
            await notifier.configurePiP(immediate: true);
            break;
          case 'auto':
            // ホームボタン時のみPiPモードに入る
            await notifier.configurePiP(immediate: false);
            break;
          case 'disable':
            // PiPを無効化
            await notifier.disablePiP();
            break;
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'immediate',
          child: ListTile(
            leading: Icon(Icons.picture_in_picture_alt),
            title: Text('今すぐPiPモードに入る'),
            subtitle: Text('即座に小窓表示'),
          ),
        ),
        PopupMenuItem(
          value: 'auto',
          child: ListTile(
            leading: Icon(Icons.home),
            title: Text('ホームボタンでPiP'),
            subtitle: Text('アプリを離れる時に小窓表示'),
          ),
        ),
        PopupMenuItem(
          value: 'disable',
          child: ListTile(
            leading: Icon(Icons.block),
            title: Text('PiPを無効化'),
            subtitle: Text('小窓表示しない'),
          ),
        ),
      ],
    );
  }
}
```

### 設定画面での実装

```dart
// PiP動作モード設定
class PiPModeSettingTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<PiPModeSettingTile> createState() => _PiPModeSettingTileState();
}

class _PiPModeSettingTileState extends ConsumerState<PiPModeSettingTile> {
  String _pipMode = 'auto'; // 'immediate', 'auto', 'disabled'
  
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text('PiPモード設定'),
      subtitle: Text(_getModeDescription()),
      trailing: DropdownButton<String>(
        value: _pipMode,
        onChanged: (value) async {
          if (value == null) return;
          
          setState(() {
            _pipMode = value;
          });
          
          final notifier = ref.read(unifiedPlayerProvider.notifier);
          
          switch (value) {
            case 'immediate':
              await notifier.configurePiP(immediate: true);
              break;
            case 'auto':
              await notifier.configurePiP(immediate: false);
              break;
            case 'disabled':
              await notifier.disablePiP();
              break;
          }
        },
        items: [
          DropdownMenuItem(
            value: 'immediate',
            child: Text('即座に起動'),
          ),
          DropdownMenuItem(
            value: 'auto',
            child: Text('自動（推奨）'),
          ),
          DropdownMenuItem(
            value: 'disabled',
            child: Text('無効'),
          ),
        ],
      ),
    );
  }
  
  String _getModeDescription() {
    switch (_pipMode) {
      case 'immediate':
        return 'PiPボタンタップで即座に小窓表示';
      case 'auto':
        return 'ホームボタンで自動的に小窓表示';
      case 'disabled':
        return 'PiP機能を使用しない';
      default:
        return '';
    }
  }
}
```

## 注意事項

1. **プラットフォーム確認**
   - AndroidPiPHelperはAndroid専用
   - 使用前に`Platform.isAndroid`でチェック

2. **エラーハンドリング**
   - MethodChannel呼び出しは失敗する可能性がある
   - try-catchで適切にエラー処理

3. **状態管理**
   - PiPの有効/無効状態を適切に管理
   - UIに状態を反映させる

4. **既存APIとの互換性**
   - `setPictureInPictureEnabled`は従来通り動作
   - 既存のコードに影響なし