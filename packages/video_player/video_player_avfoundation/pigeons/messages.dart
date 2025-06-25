// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  dartTestOut: 'test/test_api.g.dart',
  objcHeaderOut:
      'darwin/video_player_avfoundation/Sources/video_player_avfoundation/include/video_player_avfoundation/messages.g.h',
  objcSourceOut:
      'darwin/video_player_avfoundation/Sources/video_player_avfoundation/messages.g.m',
  objcOptions: ObjcOptions(
    prefix: 'FVP',
    headerIncludePath: './include/video_player_avfoundation/messages.g.h',
  ),
  copyrightHeader: 'pigeons/copyright.txt',
))

/// Pigeon equivalent of VideoViewType.
enum PlatformVideoViewType {
  textureView,
  platformView,
}

/// Information passed to the platform view creation.
class PlatformVideoViewCreationParams {
  const PlatformVideoViewCreationParams({
    required this.playerId,
  });

  final int playerId;
}

class CreationOptions {
  CreationOptions({
    required this.httpHeaders,
    required this.viewType,
  });

  String? asset;
  String? uri;
  String? packageName;
  String? formatHint;
  Map<String, String> httpHeaders;
  PlatformVideoViewType viewType;
}

@HostApi(dartHostTestHandler: 'TestHostVideoPlayerApi')
abstract class AVFoundationVideoPlayerApi {
  @ObjCSelector('initialize')
  void initialize();
  @ObjCSelector('createWithOptions:')
  // Creates a new player and returns its ID.
  int create(CreationOptions creationOptions);
  @ObjCSelector('disposePlayer:')
  void dispose(int playerId);
  @ObjCSelector('setLoopingForPlayer:isLooping:')
  void setLooping(int playerId, bool isLooping);
  @ObjCSelector('setVolumeForPlayer:volume:')
  void setVolume(int playerId, double volume);
  @ObjCSelector('setPlaybackSpeedForPlayer:speed:')
  void setPlaybackSpeed(int playerId, double speed);
  @ObjCSelector('playPlayer:')
  void play(int playerId);
  @ObjCSelector('positionForPlayer:')
  int getPosition(int playerId);
  @async
  @ObjCSelector('seekToForPlayer:position:')
  void seekTo(int playerId, int position);
  @ObjCSelector('pausePlayer:')
  void pause(int playerId);
  @ObjCSelector('setMixWithOthers:')
  void setMixWithOthers(bool mixWithOthers);
  @ObjCSelector('setPictureInPictureEnabledForPlayer:enabled:')
  void setPictureInPictureEnabled(int playerId, bool enabled);
  @ObjCSelector('isPictureInPictureSupported')
  bool isPictureInPictureSupported();
  @ObjCSelector('setNowPlayingMetadata:title:artist:album:artworkUrl:')
  void setNowPlayingMetadata(int playerId, String? title, String? artist, String? album, String? artworkUrl);
}
