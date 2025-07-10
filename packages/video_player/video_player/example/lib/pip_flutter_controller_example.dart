// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Flutter側から新しいコントローラーをPiPに適用する例
/// 
/// この例では、Flutter側で新しいVideoPlayerControllerを作成し、
/// それを既存のPiPプレイヤーに適用する方法を示します。
class PipFlutterControllerExample extends StatefulWidget {
  const PipFlutterControllerExample({super.key});

  @override
  State<PipFlutterControllerExample> createState() => _PipFlutterControllerExampleState();
}

class _PipFlutterControllerExampleState extends State<PipFlutterControllerExample> {
  VideoPlayerController? _controller;
  final List<String> _videoUrls = [
    'https://example.com/video1.mp4',
    'https://example.com/video2.mp4',
    'https://example.com/video3.mp4',
  ];
  int _currentVideoIndex = 0;
  bool _isPipActive = false;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    _checkPipStatus();
  }

  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.network(
      _videoUrls[_currentVideoIndex],
      videoPlayerOptions: const VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    await _controller!.initialize();
    setState(() {});
  }

  Future<void> _checkPipStatus() async {
    final isActive = await PipControllerManager.isPictureInPictureActive();
    setState(() {
      _isPipActive = isActive;
    });
  }

  /// 方法1: 新しいコントローラーを既存のPiPに適用
  Future<void> _applyNewControllerToPip() async {
    // 次の動画のURLを取得
    _currentVideoIndex = (_currentVideoIndex + 1) % _videoUrls.length;
    final nextVideoUrl = _videoUrls[_currentVideoIndex];
    
    // 新しいコントローラーを作成
    final newController = VideoPlayerController.network(
      nextVideoUrl,
      videoPlayerOptions: const VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    
    // 初期化
    await newController.initialize();
    
    // PiPに適用
    final success = await PipControllerManager.applyControllerToPip(
      newController: newController,
      videoUrl: nextVideoUrl,
      httpHeaders: {
        'User-Agent': 'MyApp/1.0',
      },
    );
    
    if (success) {
      // 成功したら古いコントローラーを破棄して新しいものに置き換え
      _controller?.dispose();
      setState(() {
        _controller = newController;
      });
      
      // 再生開始
      await newController.play();
      
      debugPrint('✅ 新しいコントローラーをPiPに適用しました');
    } else {
      // 失敗した場合は新しいコントローラーを破棄
      await newController.dispose();
      debugPrint('❌ PiPへの適用に失敗しました');
    }
  }

  /// 方法2: 既存のPiPプレイヤーのコンテンツのみを置き換え
  Future<void> _replaceContentInExistingPip() async {
    // 次の動画のURLを取得
    _currentVideoIndex = (_currentVideoIndex + 1) % _videoUrls.length;
    final nextVideoUrl = _videoUrls[_currentVideoIndex];
    
    // 既存のPiPプレイヤーのコンテンツを置き換え
    final success = await PipControllerManager.replaceContentInActivePip(
      videoUrl: nextVideoUrl,
      httpHeaders: {
        'User-Agent': 'MyApp/1.0',
      },
    );
    
    if (success) {
      debugPrint('✅ PiPコンテンツを置き換えました');
      // UI更新のため、必要に応じて新しいコントローラーを作成
      await _recreateControllerForUI(nextVideoUrl);
    } else {
      debugPrint('❌ コンテンツの置き換えに失敗しました');
    }
  }

  /// UI用に新しいコントローラーを作成（PiPとは別）
  Future<void> _recreateControllerForUI(String videoUrl) async {
    final newController = VideoPlayerController.network(
      videoUrl,
      videoPlayerOptions: const VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    
    await newController.initialize();
    
    _controller?.dispose();
    setState(() {
      _controller = newController;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('PiP Flutter Controller Example'),
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          VideoProgressIndicator(_controller!, allowScrubbing: true),
          
          // PiP状態表示
          Container(
            padding: const EdgeInsets.all(8),
            color: _isPipActive ? Colors.green.shade100 : Colors.grey.shade200,
            child: Text(
              'PiP: ${_isPipActive ? "アクティブ" : "非アクティブ"}',
              style: TextStyle(
                color: _isPipActive ? Colors.green : Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          
          // コントロールボタン
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // PiP開始
              IconButton(
                icon: const Icon(Icons.picture_in_picture),
                onPressed: () async {
                  await _controller!.setPictureInPictureEnabled(true);
                  await Future.delayed(const Duration(milliseconds: 500));
                  _checkPipStatus();
                },
              ),
              
              // 再生/一時停止
              IconButton(
                icon: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
              ),
            ],
          ),
          
          const Divider(),
          
          // PiP動画切り替えボタン
          if (_isPipActive) ...[
            ElevatedButton.icon(
              icon: const Icon(Icons.swap_horiz),
              label: const Text('方法1: 新しいコントローラーをPiPに適用'),
              onPressed: _applyNewControllerToPip,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('方法2: PiPコンテンツのみ置き換え'),
              onPressed: _replaceContentInExistingPip,
            ),
          ],
          
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '方法1: Flutter側で新しいコントローラーを作成し、それをPiPに適用\n'
              '方法2: 既存のPiPプレイヤーのコンテンツのみを置き換え',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}