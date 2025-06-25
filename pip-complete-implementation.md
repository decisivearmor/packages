# Video Player PiP 完全実装ガイド

## 参考資料

### 主要な Issue と Pull Request

1. **iOS PiP サポートの議論**
   - Issue: https://github.com/flutter/flutter/issues/60048
   - 「[ios][video_player] pip - picture in picture」
   - iOS での PiP 実装の必要性と課題について議論

2. **icapps による iOS PiP 実装 PR**
   - PR: https://github.com/flutter/plugins/pull/6284
   - 「[video_player] ios picture in picture」by vanlooverenkoen
   - 実際の iOS PiP 実装コードの参考

3. **関連リポジトリ**
   - 元の icapps plugins: https://github.com/icapps/plugins （アーカイブ済み）
   - 現在の flutter packages: https://github.com/flutter/packages
   - video_player_pip パッケージ: https://pub.dev/packages/video_player_pip

### Android PiP 参考資料

1. **simple_pip_mode パッケージ**
   - https://pub.dev/packages/simple_pip_mode
   - GitHub: https://github.com/PuntitOwO/simple_pip_mode_flutter

2. **Android 公式ドキュメント**
   - https://developer.android.com/guide/topics/ui/picture-in-picture

## 必要な変更ファイル一覧

### 1. Platform Interface の更新

#### ファイル: `packages/video_player/video_player_platform_interface/lib/video_player_platform_interface.dart`

`VideoPlayerPlatform` abstract class の最後（`buildView`メソッドの後）に追加:

```dart
  /// Sets Picture-in-Picture mode enabled state (iOS only).
  Future<void> setPictureInPictureEnabled(int textureId, bool enabled) {
    throw UnimplementedError('setPictureInPictureEnabled() has not been implemented.');
  }

  /// Checks if Picture-in-Picture is supported.
  Future<bool> isPictureInPictureSupported() {
    throw UnimplementedError('isPictureInPictureSupported() has not been implemented.');
  }
```

### 2. Method Channel 実装の更新

#### ファイル: `packages/video_player/video_player_platform_interface/lib/src/method_channel_video_player.dart`

`MethodChannelVideoPlayer` class の最後に追加:

```dart
  @override
  Future<void> setPictureInPictureEnabled(int textureId, bool enabled) async {
    await _channel.invokeMethod<void>(
      'setPictureInPictureEnabled',
      <String, dynamic>{
        'textureId': textureId,
        'enabled': enabled,
      },
    );
  }

  @override
  Future<bool> isPictureInPictureSupported() async {
    final bool? result = await _channel.invokeMethod<bool>('isPictureInPictureSupported');
    return result ?? false;
  }
```

### 3. Video Player Dart API の更新

#### ファイル: `packages/video_player/video_player/lib/video_player.dart`

`VideoPlayerController` class の最後（`dispose`メソッドの前）に追加:

```dart
  /// Sets Picture-in-Picture mode enabled state (iOS only).
  Future<void> setPictureInPictureEnabled(bool enabled) async {
    if (!value.isInitialized || _isDisposed) {
      throw StateError('VideoPlayerController not initialized');
    }
    
    await _videoPlayerPlatform.setPictureInPictureEnabled(_textureId, enabled);
  }

  /// Checks if Picture-in-Picture is supported.
  Future<bool> isPictureInPictureSupported() async {
    return await _videoPlayerPlatform.isPictureInPictureSupported();
  }
```

`_videoPlayerPlatform` の定義を確認し、必要であれば import を追加:

```dart
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
```

### 4. iOS ネイティブ実装

#### ファイル: `packages/video_player/video_player_avfoundation/ios/Classes/FLTVideoPlayerPlugin.m`

`handleMethodCall` メソッド内の else if チェーンの最後（`else` の前）に追加:

```objc
  } else if ([@"isPictureInPictureSupported" isEqualToString:call.method]) {
    if (@available(iOS 9.0, *)) {
      result(@([AVPictureInPictureController isPictureInPictureSupported]));
    } else {
      result(@NO);
    }
  } else if ([@"setPictureInPictureEnabled" isEqualToString:call.method]) {
    NSDictionary *argsMap = call.arguments;
    NSNumber *textureId = argsMap[@"textureId"];
    NSNumber *enabled = argsMap[@"enabled"];
    FLTVideoPlayer *player = _players[textureId];
    if (player) {
      [player setPictureInPictureEnabled:[enabled boolValue]];
      result(nil);
    } else {
      result([FlutterError errorWithCode:@"VideoPlayerError"
                                 message:@"No video player found"
                                 details:nil]);
    }
```

ファイルの先頭の import 文に追加:

```objc
#import <AVKit/AVKit.h>
```

#### ファイル: `packages/video_player/video_player_avfoundation/ios/Classes/messages.g.h`

既存のヘッダーファイルはそのまま使用（変更不要）

#### ファイル: `packages/video_player/video_player_avfoundation/ios/Classes/FLTVideoPlayer.h`

ファイルを新規作成（存在しない場合）または既存ファイルに追加:

```objc
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

@interface FLTVideoPlayer : NSObject <FlutterTexture, AVPictureInPictureControllerDelegate>
@property(readonly, nonatomic) AVPlayer *player;
@property(readonly, nonatomic) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) AVPictureInPictureController *pipController;

- (instancetype)initWithURL:(NSURL *)url frameUpdater:(FLTFrameUpdater *)frameUpdater;
- (void)play;
- (void)pause;
- (void)setIsLooping:(bool)isLooping;
- (void)setVolume:(double)volume;
- (void)setPlaybackSpeed:(double)speed;
- (void)seekTo:(int64_t)location;
- (int64_t)position;
- (int64_t)duration;
- (void)setPictureInPictureEnabled:(BOOL)enabled;
- (void)dispose;
@end
```

#### ファイル: `packages/video_player/video_player_avfoundation/ios/Classes/FLTVideoPlayer.m`

クラス実装に追加（`@implementation FLTVideoPlayer` 内）:

```objc
- (void)setPictureInPictureEnabled:(BOOL)enabled {
  if (@available(iOS 9.0, *)) {
    if (enabled && !_pipController && _playerLayer) {
      _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:_playerLayer];
      _pipController.delegate = self;
    }
    
    if (_pipController) {
      if (enabled && ![_pipController isPictureInPictureActive]) {
        [_pipController startPictureInPicture];
      } else if (!enabled && [_pipController isPictureInPictureActive]) {
        [_pipController stopPictureInPicture];
      }
    }
  }
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP開始時の処理（必要に応じて実装）
  NSLog(@"PiP will start");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP開始完了時の処理
  NSLog(@"PiP did start");
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了時の処理
  NSLog(@"PiP will stop");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了完了時の処理
  NSLog(@"PiP did stop");
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
  // PiP開始失敗時の処理
  NSLog(@"PiP failed to start: %@", error);
}
```

`dispose` メソッドに追加:

```objc
- (void)dispose {
  if (@available(iOS 9.0, *)) {
    if (_pipController && [_pipController isPictureInPictureActive]) {
      [_pipController stopPictureInPicture];
    }
    _pipController = nil;
  }
  // 既存のdispose処理...
}
```

## 実装後の手順

### 1. packages リポジトリでの作業

```bash
cd ../packages
git checkout -b feature/ios-android-pip-support
git add .
git commit -m "feat: Add Picture-in-Picture support for iOS in video_player

- Add setPictureInPictureEnabled and isPictureInPictureSupported methods
- Implement iOS native PiP using AVPictureInPictureController
- Add platform interface methods for PiP control"

git push origin feature/ios-android-pip-support
```

### 2. dlab_flutter での作業

```bash
# クリーンビルド
fvm flutter clean
fvm flutter pub get

# 拡張ファイルを削除
rm lib/extensions/video_player_pip_extension.dart
```

### 3. unified_player_provider.dart の修正

17行目の import を削除:
```dart
import '../extensions/video_player_pip_extension.dart';  // この行を削除
```

### 4. pubspec.yaml の更新（オプション）

開発が完了したら、GitHubのURLを使用するように変更:

```yaml
video_player:
  git:
    url: https://github.com/YOUR_USERNAME/packages.git
    path: packages/video_player/video_player
    ref: feature/ios-android-pip-support
```

## 注意事項

1. **AVPlayerLayer の確認**: FLTVideoPlayer の実装で _playerLayer が正しく初期化されていることを確認
2. **Info.plist の設定**: アプリ側で `UIBackgroundModes` に `audio` が含まれていることを確認（既に設定済み）
3. **iOS バージョン**: iOS 9.0以上が必要（iPadは9.0から、iPhoneは14.0から）

## テスト方法

1. iOS実機またはシミュレータ（iOS 14以上）で実行
2. 動画を再生
3. `togglePictureInPictureMode()` を呼び出してPiPモードを切り替え
4. ホームボタンを押してバックグラウンドでのPiP動作を確認