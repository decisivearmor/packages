// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.LongSparseArray;
import android.util.Rational;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;
import io.flutter.FlutterInjector;
import io.flutter.Log;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugins.videoplayer.Messages.AndroidVideoPlayerApi;
import io.flutter.plugins.videoplayer.Messages.CreateMessage;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;

/** Android platform implementation of the VideoPlayerPlugin. */
public class VideoPlayerPlugin implements FlutterPlugin, AndroidVideoPlayerApi, ActivityAware {
  private static final String TAG = "VideoPlayerPlugin";
  private final LongSparseArray<VideoPlayer> videoPlayers = new LongSparseArray<>();
  private FlutterState flutterState;
  private final VideoPlayerOptions options = new VideoPlayerOptions();
  private ActivityPluginBinding activityBinding;
  private MediaSessionHandler mediaSessionHandler;
  @Nullable
  private FlutterActivity flutterActivity;
  private final LongSparseArray<Boolean> playerAutoPipStates = new LongSparseArray<>();

  // TODO(stuartmorgan): Decouple identifiers for platform views and texture views.
  /**
   * The next non-texture player ID, initialized to a high number to avoid collisions with texture
   * IDs (which are generated separately).
   */
  private Long nextPlatformViewPlayerId = Long.MAX_VALUE;

  /** Register this with the v2 embedding for the plugin to respond to lifecycle callbacks. */
  public VideoPlayerPlugin() {}

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    final FlutterInjector injector = FlutterInjector.instance();
    this.flutterState =
        new FlutterState(
            binding.getApplicationContext(),
            binding.getBinaryMessenger(),
            injector.flutterLoader()::getLookupKeyForAsset,
            injector.flutterLoader()::getLookupKeyForAsset,
            binding.getTextureRegistry());
    flutterState.startListening(this, binding.getBinaryMessenger());

    binding
        .getPlatformViewRegistry()
        .registerViewFactory(
            "plugins.flutter.dev/video_player_android",
            new PlatformVideoViewFactory(videoPlayers::get));
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (flutterState == null) {
      Log.wtf(TAG, "Detached from the engine before registering to it.");
    }
    flutterState.stopListening(binding.getBinaryMessenger());
    flutterState = null;
    onDestroy();
  }

  private void disposeAllPlayers() {
    for (int i = 0; i < videoPlayers.size(); i++) {
      videoPlayers.valueAt(i).dispose();
    }
    videoPlayers.clear();
  }

  public void onDestroy() {
    // The whole FlutterView is being destroyed. Here we release resources acquired for all
    // instances
    // of VideoPlayer. Once https://github.com/flutter/flutter/issues/19358 is resolved this may
    // be replaced with just asserting that videoPlayers.isEmpty().
    // https://github.com/flutter/flutter/issues/20989 tracks this.
    disposeAllPlayers();
  }

  @Override
  public void initialize() {
    disposeAllPlayers();
  }

  @Override
  public @NonNull Long create(@NonNull CreateMessage arg) {
    final VideoAsset videoAsset;
    if (arg.getAsset() != null) {
      String assetLookupKey;
      if (arg.getPackageName() != null) {
        assetLookupKey =
            flutterState.keyForAssetAndPackageName.get(arg.getAsset(), arg.getPackageName());
      } else {
        assetLookupKey = flutterState.keyForAsset.get(arg.getAsset());
      }
      videoAsset = VideoAsset.fromAssetUrl("asset:///" + assetLookupKey);
    } else if (arg.getUri().startsWith("rtsp://")) {
      videoAsset = VideoAsset.fromRtspUrl(arg.getUri());
    } else {
      VideoAsset.StreamingFormat streamingFormat = VideoAsset.StreamingFormat.UNKNOWN;
      String formatHint = arg.getFormatHint();
      if (formatHint != null) {
        switch (formatHint) {
          case "ss":
            streamingFormat = VideoAsset.StreamingFormat.SMOOTH;
            break;
          case "dash":
            streamingFormat = VideoAsset.StreamingFormat.DYNAMIC_ADAPTIVE;
            break;
          case "hls":
            streamingFormat = VideoAsset.StreamingFormat.HTTP_LIVE;
            break;
        }
      }
      videoAsset = VideoAsset.fromRemoteUrl(arg.getUri(), streamingFormat, arg.getHttpHeaders());
    }

    long id;
    VideoPlayer videoPlayer;
    if (arg.getViewType() == Messages.PlatformVideoViewType.PLATFORM_VIEW) {
      id = nextPlatformViewPlayerId--;
      videoPlayer =
          PlatformViewVideoPlayer.create(
              flutterState.applicationContext,
              VideoPlayerEventCallbacks.bindTo(createEventChannel(id)),
              videoAsset,
              options);
    } else {
      TextureRegistry.SurfaceProducer handle = flutterState.textureRegistry.createSurfaceProducer();
      id = handle.id();
      videoPlayer =
          TextureVideoPlayer.create(
              flutterState.applicationContext,
              VideoPlayerEventCallbacks.bindTo(createEventChannel(id)),
              handle,
              videoAsset,
              options);
    }

    videoPlayers.put(id, videoPlayer);
    
    // Set up MediaSessionHandler for the new player
    if (mediaSessionHandler != null && videoPlayer.getExoPlayer() != null) {
      mediaSessionHandler.setPlayer(videoPlayer.getExoPlayer());
    }
    
    // Enable auto-PiP by default
    playerAutoPipStates.put(id, true);
    
    return id;
  }

  @NonNull
  private EventChannel createEventChannel(long id) {
    return new EventChannel(
        flutterState.binaryMessenger, "flutter.io/videoPlayer/videoEvents" + id);
  }

  @NonNull
  private VideoPlayer getPlayer(long playerId) {
    VideoPlayer player = videoPlayers.get(playerId);

    // Avoid a very ugly un-debuggable NPE that results in returning a null player.
    if (player == null) {
      String message = "No player found with playerId <" + playerId + ">";
      if (videoPlayers.size() == 0) {
        message += " and no active players created by the plugin.";
      }
      throw new IllegalStateException(message);
    }

    return player;
  }

  @Override
  public void dispose(@NonNull Long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.dispose();
    videoPlayers.remove(playerId);
    playerAutoPipStates.remove(playerId);
    
    // If this was the last player, hide notification
    if (videoPlayers.size() == 0 && mediaSessionHandler != null) {
      mediaSessionHandler.hideNotification();
    }
  }

  @Override
  public void setLooping(@NonNull Long playerId, @NonNull Boolean looping) {
    VideoPlayer player = getPlayer(playerId);
    player.setLooping(looping);
  }

  @Override
  public void setVolume(@NonNull Long playerId, @NonNull Double volume) {
    VideoPlayer player = getPlayer(playerId);
    player.setVolume(volume);
  }

  @Override
  public void setPlaybackSpeed(@NonNull Long playerId, @NonNull Double speed) {
    VideoPlayer player = getPlayer(playerId);
    player.setPlaybackSpeed(speed);
  }

  @Override
  public void play(@NonNull Long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.play();
  }

  @Override
  public @NonNull Long position(@NonNull Long playerId) {
    VideoPlayer player = getPlayer(playerId);
    long position = player.getPosition();
    player.sendBufferingUpdate();
    return position;
  }

  @Override
  public void seekTo(@NonNull Long playerId, @NonNull Long position) {
    VideoPlayer player = getPlayer(playerId);
    player.seekTo(position.intValue());
  }

  @Override
  public void pause(@NonNull Long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.pause();
  }

  @Override
  public void setMixWithOthers(@NonNull Boolean mixWithOthers) {
    options.mixWithOthers = mixWithOthers;
  }

  @Override
  public void setPictureInPictureEnabled(@NonNull Long playerId, @NonNull Boolean enabled) {
    VideoPlayer player = videoPlayers.get(playerId);
    if (player != null) {
      player.setPictureInPictureEnabled(enabled);
      
      // Store auto-PiP state
      playerAutoPipStates.put(playerId, enabled);
      
      // Actually enter PiP mode if enabled
      if (enabled) {
        enterPictureInPictureMode(playerId);
      }
    }
  }

  @Override
  @NonNull
  public Boolean isPictureInPictureSupported() {
    return android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O;
  }

  @Override
  public void setNowPlayingMetadata(
      @NonNull Long playerId,
      String title,
      String artist,
      String album,
      String artworkUrl) {
    VideoPlayer player = videoPlayers.get(playerId);
    if (player != null) {
      player.setNowPlayingMetadata(title, artist, album, artworkUrl);
      
      // Update MediaSession metadata
      if (mediaSessionHandler != null) {
        mediaSessionHandler.setMetadata(title, artist, album, artworkUrl);
        if (player != null && player.getExoPlayer() != null) {
          mediaSessionHandler.setPlayer(player.getExoPlayer());
        }
      }
    }
  }

  private interface KeyForAssetFn {
    String get(String asset);
  }

  private interface KeyForAssetAndPackageName {
    String get(String asset, String packageName);
  }

  private static final class FlutterState {
    final Context applicationContext;
    final BinaryMessenger binaryMessenger;
    final KeyForAssetFn keyForAsset;
    final KeyForAssetAndPackageName keyForAssetAndPackageName;
    final TextureRegistry textureRegistry;

    FlutterState(
        Context applicationContext,
        BinaryMessenger messenger,
        KeyForAssetFn keyForAsset,
        KeyForAssetAndPackageName keyForAssetAndPackageName,
        TextureRegistry textureRegistry) {
      this.applicationContext = applicationContext;
      this.binaryMessenger = messenger;
      this.keyForAsset = keyForAsset;
      this.keyForAssetAndPackageName = keyForAssetAndPackageName;
      this.textureRegistry = textureRegistry;
    }

    void startListening(VideoPlayerPlugin methodCallHandler, BinaryMessenger messenger) {
      AndroidVideoPlayerApi.setUp(messenger, methodCallHandler);
    }

    void stopListening(BinaryMessenger messenger) {
      AndroidVideoPlayerApi.setUp(messenger, null);
    }
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activityBinding = binding;
    
    // Initialize MediaSessionHandler
    if (mediaSessionHandler == null) {
      mediaSessionHandler = new MediaSessionHandler(binding.getActivity());
    }
    
    // Note: Lifecycle observation for auto-PiP is handled by the Activity's onUserLeaveHint
    // The app's MainActivity should implement onUserLeaveHint to trigger PiP
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    activityBinding = null;
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    activityBinding = binding;
  }

  @Override
  public void onDetachedFromActivity() {
    activityBinding = null;
    if (mediaSessionHandler != null) {
      mediaSessionHandler.release();
      mediaSessionHandler = null;
    }
  }
  
  private void handleAutoPiP() {
    // Check if any video is playing and has auto-PiP enabled
    for (int i = 0; i < videoPlayers.size(); i++) {
      VideoPlayer player = videoPlayers.valueAt(i);
      if (player != null && player.getExoPlayer() != null && player.getExoPlayer().isPlaying()) {
        Long playerId = videoPlayers.keyAt(i);
        Boolean autoPipEnabled = playerAutoPipStates.get(playerId);
        if (autoPipEnabled == null || autoPipEnabled) {
          // Auto-PiP is enabled by default unless explicitly disabled
          enterPictureInPictureMode(playerId);
          break;
        }
      }
    }
  }
  
  private void enterPictureInPictureMode(Long playerId) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activityBinding != null) {
      Activity activity = activityBinding.getActivity();
      VideoPlayer player = videoPlayers.get(playerId);
      
      if (activity != null && player != null && 
          activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
        
        // Build PiP parameters
        PictureInPictureParams.Builder pipBuilder = new PictureInPictureParams.Builder();
        
        // Set aspect ratio if available from video
        if (player.getExoPlayer() != null && player.getExoPlayer().getVideoSize() != null) {
          int width = player.getExoPlayer().getVideoSize().width;
          int height = player.getExoPlayer().getVideoSize().height;
          if (width > 0 && height > 0) {
            pipBuilder.setAspectRatio(new Rational(width, height));
          }
        }
        
        try {
          activity.enterPictureInPictureMode(pipBuilder.build());
        } catch (IllegalStateException e) {
          // Activity might not be in a state to enter PiP
          Log.w(TAG, "Failed to enter PiP mode: " + e.getMessage());
        }
      }
    }
  }
}
