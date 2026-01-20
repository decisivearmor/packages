// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    objcHeaderOut:
        'darwin/video_player_avfoundation/Sources/video_player_avfoundation/include/video_player_avfoundation/messages.g.h',
    objcSourceOut:
        'darwin/video_player_avfoundation/Sources/video_player_avfoundation/messages.g.m',
    objcOptions: ObjcOptions(
      prefix: 'FVP',
      headerIncludePath: './include/video_player_avfoundation/messages.g.h',
    ),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
/// Information passed to the platform view creation.
class PlatformVideoViewCreationParams {
  const PlatformVideoViewCreationParams({required this.playerId});

  final int playerId;
}

class CreationOptions {
  CreationOptions({required this.uri, required this.httpHeaders});

  String uri;
  Map<String, String> httpHeaders;
}

/// Quality selection mode for video playback.
enum PlatformQualitySelectionMode {
  /// Automatic quality selection (adaptive bitrate).
  auto,

  /// Manual quality selection (locked to specific quality).
  manual,
}

/// Represents a video quality option (variant) in an HLS stream.
class PlatformVideoQuality {
  PlatformVideoQuality({
    required this.id,
    required this.width,
    required this.height,
    required this.bitrate,
    required this.isSelected,
    this.label,
  });

  /// Unique identifier for the quality option (variant URL for iOS).
  String id;

  /// Width of the video in pixels.
  int width;

  /// Height of the video in pixels.
  int height;

  /// Bitrate of the video in bits per second.
  int bitrate;

  /// Whether this quality option is currently selected.
  bool isSelected;

  /// Human-readable label for the quality option (e.g., "1080p").
  String? label;
}

/// Metadata for Now Playing Info (lock screen / control center).
class NowPlayingMetadata {
  NowPlayingMetadata({
    this.title,
    this.artist,
    this.album,
    this.artworkUrl,
    this.isLiveStream = false,
  });

  String? title;
  String? artist;
  String? album;
  String? artworkUrl;
  bool isLiveStream;
}

class TexturePlayerIds {
  TexturePlayerIds({required this.playerId, required this.textureId});

  final int playerId;
  final int textureId;
}

@HostApi()
abstract class AVFoundationVideoPlayerApi {
  @ObjCSelector('initialize')
  void initialize();
  // Creates a new player using a platform view for rendering and returns its
  // ID.
  @ObjCSelector('createPlatformViewPlayerWithOptions:')
  int createForPlatformView(CreationOptions params);
  // Creates a new player using a texture for rendering and returns its IDs.
  @ObjCSelector('createTexturePlayerWithOptions:')
  TexturePlayerIds createForTextureView(CreationOptions creationOptions);
  @ObjCSelector('setMixWithOthers:')
  void setMixWithOthers(bool mixWithOthers);
  @ObjCSelector('fileURLForAssetWithName:package:')
  String? getAssetUrl(String asset, String? package);
}

@HostApi()
abstract class VideoPlayerInstanceApi {
  @ObjCSelector('setLooping:')
  void setLooping(bool looping);
  @ObjCSelector('setVolume:')
  void setVolume(double volume);
  @ObjCSelector('setPlaybackSpeed:')
  void setPlaybackSpeed(double speed);
  void play();
  @ObjCSelector('position')
  int getPosition();
  @async
  @ObjCSelector('seekTo:')
  void seekTo(int position);
  void pause();
  void dispose();
  /// Sets metadata for the Now Playing Info Center (lock screen / control center).
  /// Only available on iOS.
  @ObjCSelector('setNowPlayingMetadata:')
  void setNowPlayingMetadata(NowPlayingMetadata metadata);
  /// Clears the Now Playing Info Center and deactivates the audio session.
  /// Only available on iOS.
  @ObjCSelector('clearNowPlayingMetadata')
  void clearNowPlayingMetadata();

  /// Gets the available video quality options for the current HLS stream.
  ///
  /// Returns a list of available quality variants parsed from the HLS master
  /// playlist. For non-HLS streams, returns an empty list.
  @ObjCSelector('getVideoQualities')
  List<PlatformVideoQuality> getVideoQualities();

  /// Selects a specific video quality for playback.
  ///
  /// Pass [qualityId] (variant URL) to select that quality.
  /// Pass null to switch back to automatic quality selection (master playlist).
  @ObjCSelector('selectVideoQuality:')
  void selectVideoQuality(String? qualityId);

  /// Gets the current quality selection mode.
  @ObjCSelector('getQualitySelectionMode')
  PlatformQualitySelectionMode getQualitySelectionMode();
}

/// Events sent from the platform to Flutter.
enum VideoEvent {
  /// The player has initialized.
  initialized,
  /// The video completed playback.
  completed,
  /// The player started buffering.
  bufferingStart,
  /// The player ended buffering.
  bufferingEnd,
  /// The buffered regions changed.
  bufferingUpdate,
  /// The player is playing changed.
  isPlayingChanged,
  /// An error occurred.
  error,
  /// User requested next track via remote control.
  nextTrackRequested,
  /// User requested previous track via remote control.
  previousTrackRequested,
}

@FlutterApi()
abstract class VideoPlayerEventApi {
  /// Called when a video event occurs.
  void onVideoEvent(int playerId, VideoEvent event, Map<String, Object?> data);
}
