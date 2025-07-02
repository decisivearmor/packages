# ホームボタンでのPiP制御ガイド

## 概要

ホームボタンを押したときにPicture-in-Picture（PiP）モードに入るかどうかを制御する機能について説明します。

## 使用方法

### 1. ホームボタンでPiPを有効化

```dart
// ホームボタンを押したときにPiPモードに入る
await controller.setAutoPictureInPictureEnabled(true);
```

### 2. ホームボタンでPiPを無効化

```dart
// ホームボタンを押してもPiPモードに入らない
await controller.setAutoPictureInPictureEnabled(false);
```

### 3. 即座にPiPモードに入る（従来の動作）

```dart
// 即座にPiPモードに入る
await controller.setPictureInPictureEnabled(true);
```

## 動作の違い

| メソッド | 動作 | 用途 |
|---------|------|------|
| `setPictureInPictureEnabled(true)` | 即座にPiPモードに入る | PiPボタンを押したとき |
| `setAutoPictureInPictureEnabled(true)` | ホームボタンでPiPモードに入る | 動画再生中にアプリを離れるとき |
| `setAutoPictureInPictureEnabled(false)` | ホームボタンでPiPモードに入らない | PiPを無効化したいとき |

## 実装例

```dart
class VideoPlayerScreen extends StatefulWidget {
  @override
  _VideoPlayerScreenState createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  bool _autoPipEnabled = true;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.network('https://example.com/video.mp4')
      ..initialize().then((_) {
        setState(() {});
        // 初期設定：ホームボタンでPiPを有効化
        _controller.setAutoPictureInPictureEnabled(_autoPipEnabled);
      });
  }

  void _toggleAutoPip() async {
    setState(() {
      _autoPipEnabled = !_autoPipEnabled;
    });
    await _controller.setAutoPictureInPictureEnabled(_autoPipEnabled);
  }

  void _enterPipImmediately() async {
    // 即座にPiPモードに入る
    await _controller.setPictureInPictureEnabled(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Video Player'),
        actions: [
          // PiPボタン（即座にPiPに入る）
          IconButton(
            icon: Icon(Icons.picture_in_picture),
            onPressed: _enterPipImmediately,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_controller.value.isInitialized)
            AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: VideoPlayer(_controller),
            ),
          SwitchListTile(
            title: Text('ホームボタンでPiP'),
            subtitle: Text(_autoPipEnabled 
              ? 'アプリを離れるとPiPモードに入ります' 
              : 'アプリを離れてもPiPモードに入りません'),
            value: _autoPipEnabled,
            onChanged: (value) => _toggleAutoPip(),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
```

## モード切り替え

再生中にPiPモードを切り替える場合：

```dart
// 現在の設定をクリア
await controller.clearPictureInPictureSettings();

// 新しいモードを設定
await controller.setAutoPictureInPictureEnabled(true);  // または false
```

## 注意事項

1. **Android専用機能**
   - この機能はAndroid 8.0（API レベル 26）以上でのみ動作します
   - iOSでは何も起こりません

2. **動画再生中のみ有効**
   - PiPモードは動画が再生中の場合のみ動作します
   - 一時停止中はホームボタンを押してもPiPに入りません

3. **マニフェスト設定**
   - AndroidManifest.xmlでPiPサポートが有効になっている必要があります

4. **状態管理**
   - `setAutoPictureInPictureEnabled`の状態はプレイヤーごとに保持されます
   - プレイヤーを破棄すると設定もリセットされます