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
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.Messages.AndroidVideoPlayerApi;
import io.flutter.plugins.videoplayer.Messages.CreateMessage;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;

/** Android platform implementation of the VideoPlayerPlugin. */
public class VideoPlayerPlugin implements FlutterPlugin, AndroidVideoPlayerApi, ActivityAware {
  private static final String TAG = "VideoPlayerPlugin";
  // Make videoPlayers static to share across all instances
  private static final LongSparseArray<VideoPlayer> videoPlayers = new LongSparseArray<>();
  private FlutterState flutterState;
  private final VideoPlayerOptions options = new VideoPlayerOptions();
  private static ActivityPluginBinding activityBinding;
  private static MediaSessionHandler mediaSessionHandler;
  @Nullable
  private FlutterActivity flutterActivity;
  // Make playerAutoPipStates static to share across all instances
  private static final LongSparseArray<Boolean> playerAutoPipStates = new LongSparseArray<>();
  private BinaryMessenger savedBinaryMessenger;
  private MethodChannel pipMethodChannel;
  private static MethodChannel pipStateChannel;
  
  // Static instance for direct access
  private static VideoPlayerPlugin instance;

  // TODO(stuartmorgan): Decouple identifiers for platform views and texture views.
  /**
   * The next non-texture player ID, initialized to a high number to avoid collisions with texture
   * IDs (which are generated separately).
   */
  private Long nextPlatformViewPlayerId = Long.MAX_VALUE;

  /** Register this with the v2 embedding for the plugin to respond to lifecycle callbacks. */
  public VideoPlayerPlugin() {
  }
  
  // Public method for direct access from MainActivity
  public static void onUserLeaveHint() {
    if (instance != null) {
      Log.d(TAG, "onUserLeaveHint called via static method, instance=" + instance.hashCode());
      instance.handleAutoPiP();
    } else {
      Log.w(TAG, "onUserLeaveHint called but instance is null");
    }
  }

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    Log.d(TAG, "onAttachedToEngine called, this=" + this.hashCode());
    
    // Set static instance
    instance = this;
    
    final FlutterInjector injector = FlutterInjector.instance();
    
    // Save the binary messenger for later use
    savedBinaryMessenger = binding.getBinaryMessenger();
    
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
    
    // Set up method channel here in onAttachedToEngine
    setupMethodChannel(binding.getBinaryMessenger());
    
    // Set up PiP state channel for Flutter communication
    setupPipStateChannel(binding.getBinaryMessenger());
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (flutterState == null) {
      Log.wtf(TAG, "Detached from the engine before registering to it.");
    }
    flutterState.stopListening(binding.getBinaryMessenger());
    flutterState = null;
    
    // Clean up method channel
    if (pipMethodChannel != null) {
      pipMethodChannel.setMethodCallHandler(null);
      pipMethodChannel = null;
    }
    
    onDestroy();
  }

  private static void disposeAllPlayers() {
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
    Log.d(TAG, "Created video player with id: " + id + ", total players: " + videoPlayers.size() + ", instance=" + this.hashCode());
    
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
    Log.d(TAG, "play() called for player: " + playerId);
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
    Log.d(TAG, "setPictureInPictureEnabled called: playerId=" + playerId + ", enabled=" + enabled);
    VideoPlayer player = videoPlayers.get(playerId);
    if (player != null) {
      player.setPictureInPictureEnabled(enabled);
      
      // setPictureInPictureEnabledは即座PiPモードなので、自動PiPフラグはクリア
      playerAutoPipStates.remove(playerId);
      
      // Actually enter PiP mode if enabled (既存の動作を維持)
      if (enabled) {
        enterPictureInPictureMode(playerId);
      } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activityBinding != null) {
        Activity activity = activityBinding.getActivity();
        if (activity != null && activity.isInPictureInPictureMode()) {
          Log.d(TAG, "Exiting PiP mode");
          activity.moveTaskToBack(false);
        }
      }
    }
  }
  
  // 新しいメソッド: ホームボタン時のみPiPを有効化（即座にPiPに入らない）
  private void setAutoPiPEnabled(@NonNull Long playerId, @NonNull Boolean enabled) {
    Log.d(TAG, "setAutoPiPEnabled called: playerId=" + playerId + ", enabled=" + enabled);
    VideoPlayer player = videoPlayers.get(playerId);
    if (player != null) {
      // プレイヤーにPiP機能を有効化
      player.setPictureInPictureEnabled(enabled);
      
      // 自動PiPフラグを保存（trueならホームボタンでPiPに入る）
      playerAutoPipStates.put(playerId, enabled);
      
      // 即座にPiPに入らない - onUserLeaveHintでのみPiPに入る
      Log.d(TAG, "Auto PiP " + (enabled ? "enabled" : "disabled") + " for player " + playerId + " (will " + (enabled ? "" : "NOT ") + "activate on home button press)");
    }
  }
  
  // PiP設定をクリアするメソッド
  private void clearPiPSettings(@NonNull Long playerId) {
    Log.d(TAG, "clearPiPSettings called: playerId=" + playerId);
    // 自動PiPステートを削除
    playerAutoPipStates.remove(playerId);
    
    // プレイヤーのPiP設定も無効化
    VideoPlayer player = videoPlayers.get(playerId);
    if (player != null) {
      player.setPictureInPictureEnabled(false);
    }
    
    // 現在PiPモードにいる場合は終了
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activityBinding != null) {
      Activity activity = activityBinding.getActivity();
      if (activity != null && activity.isInPictureInPictureMode()) {
        Log.d(TAG, "Exiting PiP mode");
        activity.moveTaskToBack(false);
      }
    }
    
    Log.d(TAG, "PiP settings cleared for player " + playerId);
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

  private void setupMethodChannel(BinaryMessenger messenger) {
    if (messenger != null && pipMethodChannel == null) {
      pipMethodChannel = new MethodChannel(messenger, "dlab_flutter/pip");
      
      pipMethodChannel.setMethodCallHandler((call, result) -> {
        Log.d(TAG, "MethodChannel call received: " + call.method);
        if (call.method.equals("onUserLeaveHint")) {
          handleAutoPiP();
          result.success(null);
        } else if (call.method.equals("setAutoPiPEnabled")) {
          // 新しいメソッド: ホームボタン時のみPiPを有効化
          Long playerId = call.argument("playerId");
          Boolean enabled = call.argument("enabled");
          if (playerId != null && enabled != null) {
            setAutoPiPEnabled(playerId, enabled);
            result.success(null);
          } else {
            result.error("INVALID_ARGUMENTS", "playerId and enabled are required", null);
          }
        } else if (call.method.equals("clearPiPSettings")) {
          // 新しいメソッド: PiP設定をクリアして通常の動作に戻す
          Long playerId = call.argument("playerId");
          if (playerId != null) {
            clearPiPSettings(playerId);
            result.success(null);
          } else {
            result.error("INVALID_ARGUMENTS", "playerId is required", null);
          }
        } else {
          result.notImplemented();
        }
      });
      Log.d(TAG, "MethodChannel handler set up for dlab_flutter/pip, channel=" + pipMethodChannel.hashCode() + ", messenger=" + messenger.hashCode());
    }
  }
  
  private void setupPipStateChannel(BinaryMessenger messenger) {
    if (messenger != null && pipStateChannel == null) {
      pipStateChannel = new MethodChannel(messenger, "dlab_flutter/pip_state");
      Log.d(TAG, "PiP state channel set up");
    }
  }
  
  // Notify Flutter about PiP mode change
  public static void notifyPipModeChanged(boolean isInPipMode) {
    if (pipStateChannel != null) {
      Log.d(TAG, "Notifying Flutter of PiP mode change: " + isInPipMode);
      pipStateChannel.invokeMethod("onPictureInPictureModeChanged", isInPipMode);
    }
  }
  
  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    Log.d(TAG, "onAttachedToActivity called, this=" + this.hashCode() + ", binding=" + binding);
    activityBinding = binding;
    
    // Initialize MediaSessionHandler
    if (mediaSessionHandler == null) {
      mediaSessionHandler = new MediaSessionHandler(binding.getActivity());
      Log.d(TAG, "MediaSessionHandler initialized");
    }
    
    Log.d(TAG, "activityBinding set, activity=" + binding.getActivity());
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
    Log.d(TAG, "handleAutoPiP called, checking " + videoPlayers.size() + " players, instance=" + this.hashCode());
    
    // Check if any video is playing and has auto-PiP enabled
    for (int i = 0; i < videoPlayers.size(); i++) {
      VideoPlayer player = videoPlayers.valueAt(i);
      if (player != null && player.getExoPlayer() != null && player.isPictureInPictureEnabled()) {
        boolean isPlaying = player.getExoPlayer().isPlaying();
        Long playerId = videoPlayers.keyAt(i);
        Boolean autoPipEnabled = playerAutoPipStates.get(playerId);
        
        Log.d(TAG, "Player " + playerId + ": isPlaying=" + isPlaying + ", autoPipEnabled=" + autoPipEnabled + ", isPiPEnabled=" + player.isPictureInPictureEnabled());
        
        // autoPipEnabledがtrueの場合のみホームボタンでPiPに入る
        if (isPlaying && autoPipEnabled != null && autoPipEnabled) {
          Log.d(TAG, "Entering PiP for player " + playerId + " (auto mode on home button)");
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
      
      Log.d(TAG, "enterPictureInPictureMode: activity=" + (activity != null) + ", player=" + (player != null));
      
      if (activity != null && player != null && 
          activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) {
        
        // Build PiP parameters
        PictureInPictureParams.Builder pipBuilder = new PictureInPictureParams.Builder();
        
        // Set aspect ratio if available from video
        if (player.getExoPlayer() != null && player.getExoPlayer().getVideoSize() != null) {
          int width = player.getExoPlayer().getVideoSize().width;
          int height = player.getExoPlayer().getVideoSize().height;
          Log.d(TAG, "Video size: " + width + "x" + height);
          if (width > 0 && height > 0) {
            pipBuilder.setAspectRatio(new Rational(width, height));
          }
        }
        
        try {
          boolean result = activity.enterPictureInPictureMode(pipBuilder.build());
          Log.d(TAG, "enterPictureInPictureMode result: " + result);
        } catch (IllegalStateException e) {
          // Activity might not be in a state to enter PiP
          Log.w(TAG, "Failed to enter PiP mode: " + e.getMessage());
        }
      } else {
        Log.w(TAG, "Cannot enter PiP: activity=" + (activity != null) + 
              ", player=" + (player != null) + 
              ", hasPiPFeature=" + (activity != null && 
                activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)));
      }
    } else {
      Log.w(TAG, "Cannot enter PiP: SDK=" + Build.VERSION.SDK_INT + 
            ", activityBinding=" + (activityBinding != null));
    }
  }
}
