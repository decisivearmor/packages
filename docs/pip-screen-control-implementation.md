# PiP（Picture-in-Picture）画面制御実装ガイド

## 概要

特定の画面でPiPモードを無効化する実装方法について説明します。これにより、検索画面や設定画面など、PiPが不要または問題を引き起こす可能性がある画面でのみPiPを無効化できます。

## 実装方法

### 1. 画面レベルでの制御

各画面で個別にPiPの有効/無効を制御する方法：

```dart
// 例：検索画面や設定画面などでPiPを無効化
class SearchScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 画面に入ったらPiPを無効化
    ref.listen(routerProvider, (previous, next) {
      if (next.location == '/search') {
        ref.read(unifiedPlayerProvider.notifier).disablePiPForCurrentScreen();
      }
    });
    
    return WillPopScope(
      onWillPop: () async {
        // 画面を離れる時にPiPを再有効化
        ref.read(unifiedPlayerProvider.notifier).enablePiPForCurrentScreen();
        return true;
      },
      child: // 画面の内容
    );
  }
}
```

### 2. UnifiedPlayerProviderに画面制御を追加

プレイヤープロバイダーに画面制御ロジックを実装：

```dart
// unified_player_provider.dartに追加
class UnifiedPlayerNotifier extends StateNotifier<UnifiedPlayerState> {
  // PiPが無効な画面のセット
  final Set<String> _pipDisabledScreens = {
    '/search',
    '/settings',
    '/login',
    // 他にPiPを無効にしたい画面
  };
  
  bool _shouldEnablePiP = true;
  
  // 現在の画面でPiPを無効化
  void disablePiPForCurrentScreen() {
    _shouldEnablePiP = false;
    if (_videoPlayerController != null && state.isPipMode) {
      _exitPictureInPictureMode();
    }
  }
  
  // 現在の画面でPiPを有効化
  void enablePiPForCurrentScreen() {
    _shouldEnablePiP = true;
  }
  
  // playVideoメソッドを修正
  Future<void> playVideo({
    // ... 既存のパラメータ
  }) async {
    // ... 既存の処理
    
    // PiPの設定（条件付き）
    if (_shouldEnablePiP && Platform.isAndroid) {
      await _videoPlayerController!.setPictureInPictureEnabled(true);
    } else {
      await _videoPlayerController!.setPictureInPictureEnabled(false);
    }
  }
}
```

### 3. NavigatorObserverで自動制御

ナビゲーションの監視による自動制御：

```dart
// router_provider.dartに追加
class PiPNavigatorObserver extends NavigatorObserver {
  final WidgetRef ref;
  
  PiPNavigatorObserver(this.ref);
  
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _checkAndUpdatePiP(route);
  }
  
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) {
      _checkAndUpdatePiP(previousRoute);
    }
  }
  
  void _checkAndUpdatePiP(Route<dynamic> route) {
    final routeName = route.settings.name;
    final pipDisabledRoutes = ['/search', '/settings', '/login'];
    
    if (pipDisabledRoutes.contains(routeName)) {
      ref.read(unifiedPlayerProvider.notifier).disablePiPForCurrentScreen();
    } else {
      ref.read(unifiedPlayerProvider.notifier).enablePiPForCurrentScreen();
    }
  }
}
```

### 4. ライフサイクルベースの制御

StatefulWidgetのライフサイクルメソッドを使用した制御：

```dart
// 各画面のinitStateとdisposeで制御
class SearchScreen extends ConsumerStatefulWidget {
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  @override
  void initState() {
    super.initState();
    // この画面ではPiPを無効化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(unifiedPlayerProvider.notifier).disablePiPForCurrentScreen();
    });
  }
  
  @override
  void dispose() {
    // 画面を離れる時にPiPを再有効化
    ref.read(unifiedPlayerProvider.notifier).enablePiPForCurrentScreen();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    // 画面の内容
  }
}
```

## 推奨される実装方法

### 方法2と4の組み合わせ

最も柔軟で保守しやすい実装は、UnifiedPlayerProviderに制御ロジックを追加し（方法2）、各画面でライフサイクルメソッドを使用して制御する（方法4）組み合わせです。

**メリット：**
- 制御ロジックが一箇所に集約される
- 各画面で明示的に制御できる
- 将来的な拡張が容易
- デバッグが簡単

## 実装時の注意点

1. **タイミング**
   - `initState`では直接Providerを読み取れないため、`addPostFrameCallback`を使用
   - `dispose`では確実にPiPを再有効化する

2. **状態管理**
   - 現在のPiP状態を確認してから変更を適用
   - エラーハンドリングを適切に実装

3. **プラットフォーム考慮**
   - iOSではそもそもPiPが動作しないため、Androidのみで制御
   - `Platform.isAndroid`のチェックを忘れずに

4. **パフォーマンス**
   - 頻繁な有効/無効の切り替えは避ける
   - 必要な画面でのみ制御を実装

## テスト方法

1. PiPが無効化されるべき画面に遷移
2. ホームボタンを押してPiPが起動しないことを確認
3. 別の画面に遷移
4. ホームボタンを押してPiPが正常に起動することを確認

## トラブルシューティング

### PiPが無効化されない場合
- `setPictureInPictureEnabled(false)`が正しく呼ばれているか確認
- タイミングの問題がないか確認（画面遷移のタイミング）

### PiPが再有効化されない場合
- `dispose`メソッドが正しく呼ばれているか確認
- 画面遷移のフローを確認

### クラッシュする場合
- VideoPlayerControllerがnullでないか確認
- プラットフォームチェックが正しく行われているか確認