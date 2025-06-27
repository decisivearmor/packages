// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.texture;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Rational;
import android.content.res.Configuration;
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.annotation.RestrictTo;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoAsset;
import io.flutter.plugins.videoplayer.VideoPlayer;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import io.flutter.plugins.videoplayer.VideoPlayerOptions;
import io.flutter.view.TextureRegistry.SurfaceProducer;

/**
 * A subclass of {@link VideoPlayer} that adds functionality related to texture view as a way of
 * displaying the video in the app.
 *
 * <p>It manages the lifecycle of the texture and ensures that the video is properly displayed on
 * the texture.
 */
public final class TextureVideoPlayer extends VideoPlayer implements SurfaceProducer.Callback {
  // True when the ExoPlayer instance has a null surface.
  private boolean needsSurface = true;
  private Activity activity;
  private boolean isPiPActive = false;
  /**
   * Creates a texture video player.
   *
   * @param context application context.
   * @param events event callbacks.
   * @param surfaceProducer produces a texture to render to.
   * @param asset asset to play.
   * @param options options for playback.
   * @return a video player instance.
   */
  @NonNull
  public static TextureVideoPlayer create(
      @NonNull Context context,
      @NonNull VideoPlayerCallbacks events,
      @NonNull SurfaceProducer surfaceProducer,
      @NonNull VideoAsset asset,
      @NonNull VideoPlayerOptions options) {
    return new TextureVideoPlayer(
        events,
        surfaceProducer,
        asset.getMediaItem(),
        options,
        () -> {
          ExoPlayer.Builder builder =
              new ExoPlayer.Builder(context)
                  .setMediaSourceFactory(asset.getMediaSourceFactory(context));
          return builder.build();
        });
  }

  @VisibleForTesting
  public TextureVideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull SurfaceProducer surfaceProducer,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    super(events, mediaItem, options, surfaceProducer, exoPlayerProvider);

    surfaceProducer.setCallback(this);

    Surface surface = surfaceProducer.getSurface();
    this.exoPlayer.setVideoSurface(surface);
    needsSurface = surface == null;
  }

  @NonNull
  @Override
  protected ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer) {
    if (surfaceProducer == null) {
      throw new IllegalArgumentException(
          "surfaceProducer cannot be null to create an ExoPlayerEventListener for TextureVideoPlayer.");
    }
    boolean surfaceProducerHandlesCropAndRotation = surfaceProducer.handlesCropAndRotation();
    return new TextureExoPlayerEventListener(
        exoPlayer, videoPlayerEvents, surfaceProducerHandlesCropAndRotation);
  }

  @RestrictTo(RestrictTo.Scope.LIBRARY)
  public void onSurfaceAvailable() {
    if (needsSurface) {
      // TextureVideoPlayer must always set a surfaceProducer.
      assert surfaceProducer != null;
      exoPlayer.setVideoSurface(surfaceProducer.getSurface());
      needsSurface = false;
    }
  }

  @RestrictTo(RestrictTo.Scope.LIBRARY)
  public void onSurfaceCleanup() {
    exoPlayer.setVideoSurface(null);
    needsSurface = true;
  }

  public void dispose() {
    // Super must be called first to ensure the player is released before the surface.
    super.dispose();

    // TextureVideoPlayer must always set a surfaceProducer.
    assert surfaceProducer != null;
    surfaceProducer.release();
  }

  @Override
  public void setPictureInPictureEnabled(boolean enabled) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && activity != null) {
      if (enabled) {
        enterPictureInPictureMode();
      } else if (isPiPActive) {
        // Exit PiP by returning to app
        activity.moveTaskToBack(false);
      }
    }
  }
  
  @RequiresApi(api = Build.VERSION_CODES.O)
  private void enterPictureInPictureMode() {
    if (activity == null || exoPlayer == null) {
      return;
    }
    
    // Calculate aspect ratio from video
    int videoWidth = exoPlayer.getVideoSize().width;
    int videoHeight = exoPlayer.getVideoSize().height;
    
    if (videoWidth == 0 || videoHeight == 0) {
      // Default aspect ratio if video size not available
      videoWidth = 16;
      videoHeight = 9;
    }
    
    Rational aspectRatio = new Rational(videoWidth, videoHeight);
    PictureInPictureParams.Builder paramsBuilder = new PictureInPictureParams.Builder()
        .setAspectRatio(aspectRatio);
    
    // Android 12+ can set auto enter PiP
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      paramsBuilder.setAutoEnterEnabled(true)
          .setSeamlessResizeEnabled(true);
    }
    
    try {
      boolean result = activity.enterPictureInPictureMode(paramsBuilder.build());
      if (result) {
        isPiPActive = true;
      }
    } catch (IllegalStateException e) {
      // Handle the case where PiP is not supported or activity state doesn't allow it
      e.printStackTrace();
    }
  }
  
  public void setActivity(Activity activity) {
    this.activity = activity;
  }
  
  public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
    this.isPiPActive = isInPictureInPictureMode;
    if (!isInPictureInPictureMode) {
      // Returned from PiP to fullscreen
      // Resume normal playback if needed
    }
  }

  @Override
  public void setNowPlayingMetadata(
      String title, String artist, String album, String artworkUrl) {
    if (exoPlayer != null) {
      // In Media3, metadata should be set through MediaItem when preparing the player
      // For now, we'll store these values and they should be applied when setting up the MediaItem
      // This is a simplified implementation that doesn't actively update existing playback
      
      // TODO: Implement proper MediaSession integration for background playback metadata
      // The metadata should be set through MediaSession for proper media controls
      // in the notification area and lock screen
    }
  }
}
