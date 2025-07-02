# 正しいPiP実装ガイド

## 問題点

提示されたコードの問題：

```dart
// 問題のあるコード
_videoPlayerController!.setAutoPictureInPictureEnabled(true).then((_) {
  state = state.copyWith(isPipMode: true); // ❌ これは間違い
});
```

**なぜ間違いか：**
- `setAutoPictureInPictureEnabled(true)`は「ホームボタンを押したときにPiPに入る」設定
- 即座にPiPモードに入るわけではない
- `isPipMode: true`は実際にPiPモードに入った時のみ設定すべき

## 正しい実装

### 1. PlayerViewStateに応じたPiP制御

```dart
// player_manager.dart

void _handleViewStateChange(PlayerViewState previous, PlayerViewState next) {
  // 通常のビデオプレイヤーの場合
  if (state.mediaType == MediaType.video && _videoPlayerController != null) {
    
    // フルプレイヤー表示時：ホームボタンでPiPを有効化
    if (next == PlayerViewState.full) {
      _configurePiPForFullPlayer();
    }
    
    // ミニプレイヤー表示時：PiPを無効化
    else if (next == PlayerViewState.mini) {
      _disablePiP();
    }
    
    // 非表示時：PiPを無効化
    else if (next == PlayerViewState.hidden) {
      _disablePiP();
    }
  }
}

// フルプレイヤー用のPiP設定
Future<void> _configurePiPForFullPlayer() async {
  if (_videoPlayerController == null || !Platform.isAndroid) return;
  
  try {
    // 既存のPiP設定をクリア
    await _videoPlayerController!.clearPictureInPictureSettings();
    
    // ホームボタンでPiPに入る設定
    await _videoPlayerController!.setAutoPictureInPictureEnabled(true);
    
    Logger().i('PiP自動モードを有効化（ホームボタンでPiP）');
    
    // 注意：ここでisPipMode: trueにはしない！
    // 実際にPiPモードに入った時のみtrueにする
    
  } catch (e) {
    Logger().e('PiP設定エラー: $e');
  }
}

// PiPを無効化
Future<void> _disablePiP() async {
  if (_videoPlayerController == null || !Platform.isAndroid) return;
  
  try {
    // PiP設定をクリア
    await _videoPlayerController!.clearPictureInPictureSettings();
    
    // 現在PiPモードにいる場合は終了
    if (state.isPipMode) {
      await _exitPictureInPictureMode();
    }
    
    Logger().i('PiPを無効化');
    
  } catch (e) {
    Logger().e('PiP無効化エラー: $e');
  }
}
```

### 2. PiPモード状態の正しい管理

```dart
// PiP状態を監視するサービス（pip_service.dart）を活用
class PipService {
  static const MethodChannel _channel = MethodChannel('your_app/pip_state');
  
  static void initialize(WidgetRef ref) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPictureInPictureModeChanged') {
        final isInPipMode = call.arguments as bool;
        
        // ここで実際のPiP状態を更新
        ref.read(pipModeProvider.notifier).state = isInPipMode;
        
        // PlayerProviderの状態も更新
        ref.read(playerProvider.notifier).updatePipModeState(isInPipMode);
        
        print('PiP mode changed: $isInPipMode');
      }
    });
  }
}

// player_provider.dartに追加
void updatePipModeState(bool isInPipMode) {
  state = state.copyWith(isPipMode: isInPipMode);
  Logger().i('PiPモード状態更新: $isInPipMode');
}
```

### 3. PiPボタンの実装

```dart
// プレイヤーコントロールのPiPボタン
class PiPButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playerState = ref.watch(playerProvider);
    final viewState = ref.watch(playerViewStateProvider);
    
    // フルプレイヤー表示時のみPiPボタンを表示
    if (viewState != PlayerViewState.full || !Platform.isAndroid) {
      return SizedBox.shrink();
    }
    
    return IconButton(
      icon: Icon(
        playerState.isPipMode 
          ? Icons.picture_in_picture_alt 
          : Icons.picture_in_picture_outlined,
      ),
      onPressed: () async {
        if (playerState.isPipMode) {
          // 既にPiPモードの場合は何もしない
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('既にPiPモードです')),
          );
        } else {
          // 即座にPiPモードに入る
          await ref.read(playerProvider.notifier)
              .enterPictureInPictureImmediately();
        }
      },
      tooltip: 'ピクチャーインピクチャー',
    );
  }
}

// player_provider.dartに追加
Future<void> enterPictureInPictureImmediately() async {
  if (_videoPlayerController == null || !Platform.isAndroid) return;
  
  try {
    // 即座にPiPモードに入る
    await _videoPlayerController!.setPictureInPictureEnabled(true);
    // 注意：isPipModeの更新はAndroid側からのコールバックで行われる
  } catch (e) {
    Logger().e('PiP開始エラー: $e');
  }
}
```

### 4. 完全な実装例

```dart
// player_manager.dart

// PiP設定タイプ
enum PiPSettingType {
  none,        // PiP無効
  automatic,   // ホームボタンでPiP
  immediate,   // 即座にPiP
}

class PlayerManager {
  PiPSettingType _currentPiPSetting = PiPSettingType.none;
  
  // ビューステート変更時の処理
  void _handleViewStateChange(PlayerViewState previous, PlayerViewState next) {
    if (state.mediaType == MediaType.video && _videoPlayerController != null) {
      switch (next) {
        case PlayerViewState.full:
          // フルプレイヤー：自動PiPを有効化
          _applyPiPSetting(PiPSettingType.automatic);
          break;
          
        case PlayerViewState.mini:
        case PlayerViewState.hidden:
          // ミニプレイヤーまたは非表示：PiPを無効化
          _applyPiPSetting(PiPSettingType.none);
          break;
          
        case PlayerViewState.fullscreen:
          // フルスクリーン：現在の設定を維持
          break;
      }
    }
  }
  
  // PiP設定を適用
  Future<void> _applyPiPSetting(PiPSettingType type) async {
    if (_videoPlayerController == null || !Platform.isAndroid) return;
    
    try {
      // 既存の設定をクリア
      await _videoPlayerController!.clearPictureInPictureSettings();
      
      switch (type) {
        case PiPSettingType.none:
          // PiP無効
          _currentPiPSetting = type;
          Logger().i('PiP無効化');
          break;
          
        case PiPSettingType.automatic:
          // ホームボタンでPiP
          await _videoPlayerController!.setAutoPictureInPictureEnabled(true);
          _currentPiPSetting = type;
          Logger().i('自動PiP有効化（ホームボタン）');
          break;
          
        case PiPSettingType.immediate:
          // 即座にPiP
          await _videoPlayerController!.setPictureInPictureEnabled(true);
          _currentPiPSetting = type;
          Logger().i('即座にPiPモードへ');
          break;
      }
    } catch (e) {
      Logger().e('PiP設定エラー: $e');
    }
  }
  
  // Android側からのPiP状態更新
  void updatePipModeState(bool isInPipMode) {
    state = state.copyWith(isPipMode: isInPipMode);
    Logger().i('PiPモード状態更新: $isInPipMode');
    
    // PiPモードから抜けた場合、現在のビューステートに応じて再設定
    if (!isInPipMode && mounted) {
      final currentViewState = ref.read(playerViewStateProvider);
      _handleViewStateChange(currentViewState, currentViewState);
    }
  }
}
```

## 重要なポイント

1. **isPipModeの更新タイミング**
   - `setAutoPictureInPictureEnabled(true)`の後ではない
   - Android側からの`onPictureInPictureModeChanged`コールバックで更新

2. **ビューステートとPiP設定の連動**
   - フルプレイヤー：自動PiP有効
   - ミニプレイヤー：PiP無効
   - 非表示：PiP無効

3. **clearPictureInPictureSettings()の使用**
   - 設定を変更する前に必ず呼び出す
   - これにより前の設定との競合を防ぐ

4. **エラーハンドリング**
   - すべてのPiP操作をtry-catchで保護
   - Android以外のプラットフォームでは何もしない