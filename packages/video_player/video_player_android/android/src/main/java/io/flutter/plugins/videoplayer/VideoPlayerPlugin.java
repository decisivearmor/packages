// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.Activity;
import android.app.PendingIntent;
import android.app.PictureInPictureParams;
import android.app.RemoteAction;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Rect;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.util.LongSparseArray;
import android.util.Rational;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import java.util.ArrayList;
import java.util.List;
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
  
  // PiP action constants
  private static final String ACTION_PLAY_PAUSE = "io.flutter.plugins.videoplayer.ACTION_PLAY_PAUSE";
  private static final String ACTION_REWIND = "io.flutter.plugins.videoplayer.ACTION_REWIND";
  private static final String ACTION_FAST_FORWARD = "io.flutter.plugins.videoplayer.ACTION_FAST_FORWARD";
  private static final String ACTION_MEDIA_CONTROL = "io.flutter.plugins.videoplayer.ACTION_MEDIA_CONTROL";
  
  // PiP action request codes
  private static final int REQUEST_PLAY_PAUSE = 1;
  private static final int REQUEST_REWIND = 2;
  private static final int REQUEST_FAST_FORWARD = 3;
  private static final int REQUEST_PLAY = 4;
  private static final int REQUEST_PAUSE = 5;
  private static final int REQUEST_REPLAY = 6;
  private static final int REQUEST_FORWARD = 7;
  
  // Control type constants
  private static final int CONTROL_TYPE_PLAY = 1;
  private static final int CONTROL_TYPE_PAUSE = 2;
  private static final int CONTROL_TYPE_REPLAY = 3;
  private static final int CONTROL_TYPE_FORWARD = 4;
  
  // Intent extras
  private static final String EXTRA_CONTROL_TYPE = "control_type";
  private static final String EXTRA_PLAYER_ID = "player_id";
  
  // PiP action receiver
  private BroadcastReceiver pipActionReceiver;

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

  private void setupMethodChannel(BinaryMessenger messenger) {
    if (messenger != null && pipMethodChannel == null) {
      pipMethodChannel = new MethodChannel(messenger, "dlab_flutter/pip");
      
      pipMethodChannel.setMethodCallHandler((call, result) -> {
        Log.d(TAG, "MethodChannel call received: " + call.method);
        if (call.method.equals("onUserLeaveHint")) {
          handleAutoPiP();
          result.success(null);
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
    
    // Register PiP action receiver
    registerPipActionReceiver(binding.getActivity());
    
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
    // Unregister PiP action receiver
    if (activityBinding != null && activityBinding.getActivity() != null) {
      unregisterPipActionReceiver(activityBinding.getActivity());
    }
    
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
      if (player != null && player.getExoPlayer() != null) {
        boolean isPlaying = player.getExoPlayer().isPlaying();
        Long playerId = videoPlayers.keyAt(i);
        Boolean autoPipEnabled = playerAutoPipStates.get(playerId);
        
        Log.d(TAG, "Player " + playerId + ": isPlaying=" + isPlaying + ", autoPipEnabled=" + autoPipEnabled);
        
        if (isPlaying && (autoPipEnabled == null || autoPipEnabled)) {
          // Auto-PiP is enabled by default unless explicitly disabled
          Log.d(TAG, "Entering PiP for player " + playerId);
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
        
        // Android 12+ features
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
          // Enable automatic PiP transition for smoother UX
          pipBuilder.setAutoEnterEnabled(true);
          // Keep seamless resize enabled for video content
          pipBuilder.setSeamlessResizeEnabled(true);
        }
        
        // Add setSourceRectHint() if we can get player view bounds
        // For TextureVideoPlayer, we would need to get the bounds from Flutter
        // For PlatformViewVideoPlayer, we can try to get bounds from the view
        if (player instanceof PlatformViewVideoPlayer) {
          Rect sourceRect = getPlayerViewBounds(playerId);
          if (sourceRect != null && !sourceRect.isEmpty()) {
            pipBuilder.setSourceRectHint(sourceRect);
            Log.d(TAG, "Setting source rect hint: " + sourceRect);
          }
        }
        
        // Add custom actions for media controls
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          List<RemoteAction> actions = createMediaActions(activity, playerId, player);
          Log.d(TAG, "Created " + actions.size() + " PiP actions for player " + playerId);
          if (!actions.isEmpty()) {
            pipBuilder.setActions(actions);
          }
        }
        
        try {
          // For Android 12+, update PiP params before entering
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.setPictureInPictureParams(pipBuilder.build());
          }
          
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
  
  @RequiresApi(api = Build.VERSION_CODES.O)
  private List<RemoteAction> createMediaActions(Context context, Long playerId, VideoPlayer player) {
    List<RemoteAction> actions = new ArrayList<>();
    
    boolean isPlaying = player.getExoPlayer() != null && player.getExoPlayer().isPlaying();
    
    // Play/Pause action
    Icon playPauseIcon = Icon.createWithResource(context.getPackageName(),
        isPlaying ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play);
    String playPauseTitle = isPlaying ? "Pause" : "Play";
    PendingIntent playPauseIntent = createPendingIntent(context, 
        isPlaying ? CONTROL_TYPE_PAUSE : CONTROL_TYPE_PLAY, playerId);
    RemoteAction playPauseAction = new RemoteAction(playPauseIcon, playPauseTitle, 
        playPauseTitle, playPauseIntent);
    actions.add(playPauseAction);
    
    // Replay action (10 seconds back)
    Icon replayIcon = Icon.createWithResource(context.getPackageName(), 
        android.R.drawable.ic_media_rew);
    PendingIntent replayIntent = createPendingIntent(context, CONTROL_TYPE_REPLAY, playerId);
    RemoteAction replayAction = new RemoteAction(replayIcon, "Replay", 
        "Go back 10 seconds", replayIntent);
    actions.add(replayAction);
    
    // Forward action (10 seconds forward)
    Icon forwardIcon = Icon.createWithResource(context.getPackageName(), 
        android.R.drawable.ic_media_ff);
    PendingIntent forwardIntent = createPendingIntent(context, CONTROL_TYPE_FORWARD, playerId);
    RemoteAction forwardAction = new RemoteAction(forwardIcon, "Forward", 
        "Go forward 10 seconds", forwardIntent);
    actions.add(forwardAction);
    
    return actions;
  }
  
  private PendingIntent createPendingIntent(Context context, int controlType, Long playerId) {
    Intent intent = new Intent(ACTION_MEDIA_CONTROL);
    intent.putExtra(EXTRA_CONTROL_TYPE, controlType);
    intent.putExtra(EXTRA_PLAYER_ID, playerId);
    intent.setPackage(context.getPackageName()); // 明示的にパッケージを設定
    
    Log.d(TAG, "Creating PendingIntent: action=" + ACTION_MEDIA_CONTROL + 
        ", controlType=" + controlType + ", playerId=" + playerId);
    
    int flags = PendingIntent.FLAG_UPDATE_CURRENT;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      flags |= PendingIntent.FLAG_IMMUTABLE;
    }
    
    // requestCodeとしてcontrolTypeを使用
    return PendingIntent.getBroadcast(context, controlType, intent, flags);
  }
  
  private void registerPipActionReceiver(Context context) {
    Log.d(TAG, "registerPipActionReceiver called, context=" + context);
    if (pipActionReceiver == null) {
      pipActionReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
          Log.d(TAG, "PiP BroadcastReceiver onReceive called");
          if (ACTION_MEDIA_CONTROL.equals(intent.getAction())) {
            int controlType = intent.getIntExtra(EXTRA_CONTROL_TYPE, 0);
            long playerId = intent.getLongExtra(EXTRA_PLAYER_ID, -1);
            
            Log.d(TAG, "PiP action received: controlType=" + controlType + ", playerId=" + playerId);
            
            if (playerId != -1) {
              VideoPlayer player = videoPlayers.get(playerId);
              if (player != null && player.getExoPlayer() != null) {
                Log.d(TAG, "Executing PiP action: " + controlType);
                switch (controlType) {
                  case CONTROL_TYPE_PLAY:
                    Log.d(TAG, "PiP: Playing");
                    player.play();
                    updatePipActions(playerId);
                    break;
                  case CONTROL_TYPE_PAUSE:
                    Log.d(TAG, "PiP: Pausing");
                    player.pause();
                    updatePipActions(playerId);
                    break;
                  case CONTROL_TYPE_REPLAY:
                    Log.d(TAG, "PiP: Rewinding 10s");
                    long currentPosition = player.getPosition();
                    player.seekTo((int) Math.max(0, currentPosition - 10000));
                    break;
                  case CONTROL_TYPE_FORWARD:
                    Log.d(TAG, "PiP: Forwarding 10s");
                    long position = player.getPosition();
                    long duration = player.getExoPlayer().getDuration();
                    player.seekTo((int) Math.min(duration, position + 10000));
                    break;
                }
              } else {
                Log.w(TAG, "PiP: Player not found or ExoPlayer is null");
              }
            } else {
              Log.w(TAG, "PiP: Invalid playerId");
            }
          }
        }
      };
      
      IntentFilter filter = new IntentFilter(ACTION_MEDIA_CONTROL);
      context.registerReceiver(pipActionReceiver, filter);
      Log.d(TAG, "PiP BroadcastReceiver registered for action: " + ACTION_MEDIA_CONTROL);
    }
  }
  
  private void unregisterPipActionReceiver(Context context) {
    if (pipActionReceiver != null) {
      context.unregisterReceiver(pipActionReceiver);
      pipActionReceiver = null;
    }
  }
  
  private void updatePipActions(Long playerId) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activityBinding != null) {
      Activity activity = activityBinding.getActivity();
      VideoPlayer player = videoPlayers.get(playerId);
      
      if (activity != null && player != null) {
        PictureInPictureParams.Builder pipBuilder = new PictureInPictureParams.Builder();
        
        // Set aspect ratio
        if (player.getExoPlayer() != null && player.getExoPlayer().getVideoSize() != null) {
          int width = player.getExoPlayer().getVideoSize().width;
          int height = player.getExoPlayer().getVideoSize().height;
          if (width > 0 && height > 0) {
            pipBuilder.setAspectRatio(new Rational(width, height));
          }
        }
        
        // Update actions
        List<RemoteAction> actions = createMediaActions(activity, playerId, player);
        if (!actions.isEmpty()) {
          pipBuilder.setActions(actions);
        }
        
        try {
          activity.setPictureInPictureParams(pipBuilder.build());
        } catch (IllegalStateException e) {
          Log.w(TAG, "Failed to update PiP params: " + e.getMessage());
        }
      }
    }
  }
  
  @Nullable
  private Rect getPlayerViewBounds(Long playerId) {
    // This method would need to be implemented to get actual view bounds
    // For PlatformViewVideoPlayer, we could potentially access the view
    // through the platform view registry
    // For now, returning null to use default behavior
    return null;
  }
}
