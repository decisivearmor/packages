// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

/// PiPモード中のコントローラー切り替えを管理するクラス
/// 
/// このクラスは、Flutter側で新しいVideoPlayerControllerを作成した際に、
/// それを既存のPiPプレイヤーに適用するための機能を提供します。
class PipControllerManager {
  static const MethodChannel _channel = MethodChannel('plugins.flutter.io/video_player');
  
  /// 現在PiPモードで表示中のプレイヤーID
  static int? _activePipPlayerId;
  
  /// PiPモードがアクティブかどうか
  static bool _isPipActive = false;
  
  /// 現在のPiPプレイヤーIDを取得
  static int? get activePipPlayerId => _activePipPlayerId;
  
  /// PiPモードの状態を更新
  static void updatePipState(bool isActive, int? playerId) {
    _isPipActive = isActive;
    _activePipPlayerId = isActive ? playerId : null;
  }
  
  /// 新しいコントローラーを既存のPiPプレイヤーに適用
  /// 
  /// Flutter側で新しいVideoPlayerControllerを作成した後、
  /// このメソッドを呼び出すことで、既存のPiPプレイヤーに
  /// 新しいコンテンツを設定できます。
  static Future<bool> applyControllerToPip({
    required VideoPlayerController newController,
    required String videoUrl,
    Map<String, String>? httpHeaders,
  }) async {
    if (!_isPipActive || _activePipPlayerId == null) {
      print('📺 PiPが非アクティブです');
      return false;
    }
    
    try {
      // ネイティブ側に新しいコンテンツの適用を要求
      final result = await _channel.invokeMethod<bool>('updatePipContent', {
        'activePipPlayerId': _activePipPlayerId,
        'newPlayerId': newController.playerId,
        'videoUrl': videoUrl,
        'httpHeaders': httpHeaders ?? {},
      });
      
      if (result == true) {
        print('✅ PiPプレイヤーのコンテンツを更新しました');
        // 新しいプレイヤーIDを記録
        _activePipPlayerId = newController.playerId;
        return true;
      }
    } catch (e) {
      print('❌ PiPコンテンツの更新に失敗: $e');
    }
    
    return false;
  }
  
  /// PiPモード中かどうかを確認
  static Future<bool> isPictureInPictureActive() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPipStatus');
      if (result != null) {
        _isPipActive = result['isActive'] as bool? ?? false;
        _activePipPlayerId = result['playerId'] as int?;
        return _isPipActive;
      }
    } catch (e) {
      print('PiP状態の取得に失敗: $e');
    }
    return false;
  }
  
  /// 既存のPiPプレイヤーを使用して新しいコンテンツを再生
  /// 
  /// この方法では、新しいVideoPlayerControllerは作成せず、
  /// 既存のPiPプレイヤーのコンテンツのみを更新します。
  static Future<bool> replaceContentInActivePip({
    required String videoUrl,
    Map<String, String>? httpHeaders,
  }) async {
    if (!_isPipActive || _activePipPlayerId == null) {
      return false;
    }
    
    try {
      final result = await _channel.invokeMethod<bool>('replaceContentInPip', {
        'playerId': _activePipPlayerId,
        'videoUrl': videoUrl,
        'httpHeaders': httpHeaders ?? {},
      });
      
      return result ?? false;
    } catch (e) {
      print('PiPコンテンツの置き換えに失敗: $e');
      return false;
    }
  }
}