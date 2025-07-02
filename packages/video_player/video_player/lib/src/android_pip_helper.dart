import 'package:flutter/services.dart';

/// Android用のPiPヘルパークラス
/// ホームボタン押下時のみPiPモードに入る設定を提供
class AndroidPiPHelper {
  static const MethodChannel _channel = MethodChannel('dlab_flutter/pip');
  
  /// ホームボタン押下時のみPiPを有効化する設定
  /// [playerId] - VideoPlayerControllerのtextureId
  /// [enabled] - 有効/無効の設定
  /// 
  /// 使用例:
  /// ```dart
  /// // ホームボタン時のみPiPを有効化
  /// await AndroidPiPHelper.setAutoPiPEnabled(
  ///   controller.textureId,
  ///   true,
  /// );
  /// ```
  static Future<void> setAutoPiPEnabled(int playerId, bool enabled) async {
    try {
      await _channel.invokeMethod('setAutoPiPEnabled', {
        'playerId': playerId,
        'enabled': enabled,
      });
    } catch (e) {
      print('Error setting auto PiP: $e');
    }
  }
  
  /// 現在のPiP設定状態を取得（将来の拡張用）
  static Future<bool?> getAutoPiPEnabled(int playerId) async {
    // TODO: 実装が必要な場合は追加
    return null;
  }
}