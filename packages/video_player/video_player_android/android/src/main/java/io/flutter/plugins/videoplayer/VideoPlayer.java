// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static androidx.media3.common.Player.REPEAT_MODE_ALL;
import static androidx.media3.common.Player.REPEAT_MODE_OFF;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.session.MediaSession;
import androidx.media3.session.SessionCommand;
import androidx.media3.session.SessionResult;

import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

import io.flutter.view.TextureRegistry.SurfaceProducer;

/**
 * A class responsible for managing video playback using {@link ExoPlayer}.
 *
 * <p>It provides methods to control playback, adjust volume, and handle seeking.
 */
public abstract class VideoPlayer implements VideoPlayerInstanceApi {
  @NonNull protected final VideoPlayerCallbacks videoPlayerEvents;
  @Nullable protected final SurfaceProducer surfaceProducer;
  @Nullable private DisposeHandler disposeHandler;
  @NonNull protected ExoPlayer exoPlayer;
  @Nullable protected MediaSession mediaSession;
  @Nullable protected Context context;

  /** A closure-compatible signature since {@link java.util.function.Supplier} is API level 24. */
  public interface ExoPlayerProvider {
    /**
     * Returns a new {@link ExoPlayer}.
     *
     * @return new instance.
     */
    @NonNull
    ExoPlayer get();
  }

  /** A handler to run when dispose is called. */
  public interface DisposeHandler {
    void onDispose();
  }

  // Error thrown for this-escape warning on JDK 21+ due to https://bugs.openjdk.org/browse/JDK-8015831.
  // Keeping behavior as-is and addressing the warning could cause a regression: https://github.com/flutter/packages/pull/10193
  @SuppressWarnings("this-escape")
  public VideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @Nullable SurfaceProducer surfaceProducer,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    this.videoPlayerEvents = events;
    this.surfaceProducer = surfaceProducer;
    exoPlayer = exoPlayerProvider.get();
    exoPlayer.setMediaItem(mediaItem);
    exoPlayer.prepare();
    exoPlayer.addListener(createExoPlayerEventListener(exoPlayer, surfaceProducer));
    setAudioAttributes(exoPlayer, options.mixWithOthers);
  }

  public void setDisposeHandler(@Nullable DisposeHandler handler) {
    disposeHandler = handler;
  }

  @NonNull
  protected abstract ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer);

  private static void setAudioAttributes(ExoPlayer exoPlayer, boolean isMixMode) {
    exoPlayer.setAudioAttributes(
        new AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
        !isMixMode);
  }

  @Override
  public void play() {
    exoPlayer.play();
  }

  @Override
  public void pause() {
    exoPlayer.pause();
  }

  @Override
  public void setLooping(boolean looping) {
    exoPlayer.setRepeatMode(looping ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
  }

  @Override
  public void setVolume(double volume) {
    float bracketedValue = (float) Math.max(0.0, Math.min(1.0, volume));
    exoPlayer.setVolume(bracketedValue);
  }

  @Override
  public void setPlaybackSpeed(double speed) {
    // We do not need to consider pitch and skipSilence for now as we do not handle them and
    // therefore never diverge from the default values.
    final PlaybackParameters playbackParameters = new PlaybackParameters((float) speed);

    exoPlayer.setPlaybackParameters(playbackParameters);
  }

  @Override
  public long getCurrentPosition() {
    return exoPlayer.getCurrentPosition();
  }

  @Override
  public long getBufferedPosition() {
    return exoPlayer.getBufferedPosition();
  }

  @Override
  public void seekTo(long position) {
    exoPlayer.seekTo(position);
  }

  @NonNull
  public ExoPlayer getExoPlayer() {
    return exoPlayer;
  }

  public void dispose() {
    if (disposeHandler != null) {
      disposeHandler.onDispose();
    }
    releaseMediaSession();
    exoPlayer.release();
  }

  @Override
  public void setNowPlayingMetadata(@NonNull NowPlayingMetadata metadata) {
    if (context == null) {
      return;
    }

    // Build MediaMetadata for the ExoPlayer
    MediaMetadata.Builder metadataBuilder = new MediaMetadata.Builder();

    if (metadata.getTitle() != null) {
      metadataBuilder.setTitle(metadata.getTitle());
    }
    if (metadata.getArtist() != null) {
      metadataBuilder.setArtist(metadata.getArtist());
    }
    if (metadata.getAlbum() != null) {
      metadataBuilder.setAlbumTitle(metadata.getAlbum());
    }
    if (metadata.getArtworkUrl() != null) {
      try {
        metadataBuilder.setArtworkUri(Uri.parse(metadata.getArtworkUrl()));
      } catch (Exception e) {
        // Ignore invalid URI
      }
    }

    MediaMetadata mediaMetadata = metadataBuilder.build();

    // Update the current MediaItem with metadata
    MediaItem currentItem = exoPlayer.getCurrentMediaItem();
    if (currentItem != null) {
      MediaItem updatedItem = currentItem.buildUpon()
          .setMediaMetadata(mediaMetadata)
          .build();
      exoPlayer.replaceMediaItem(exoPlayer.getCurrentMediaItemIndex(), updatedItem);
    }

    // Set up event callbacks for track navigation
    if (videoPlayerEvents instanceof VideoPlayerEventCallbacks) {
      VideoPlayerMediaService.setEventCallbacks((VideoPlayerEventCallbacks) videoPlayerEvents);
    }

    // Set the player on the MediaService and start it
    // Pass isLiveStream flag to control which buttons are shown
    VideoPlayerMediaService.setPlayer(exoPlayer, metadata.isLiveStream());
    startMediaService();
  }

  @Override
  public void clearNowPlayingMetadata() {
    stopMediaService();
  }

  private void startMediaService() {
    if (context == null) {
      return;
    }
    try {
      Intent serviceIntent = new Intent(context, VideoPlayerMediaService.class);
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(serviceIntent);
      } else {
        context.startService(serviceIntent);
      }
      Log.d("VideoPlayer", "MediaService started");
    } catch (Exception e) {
      Log.e("VideoPlayer", "Failed to start MediaService: " + e.getMessage());
    }
  }

  private void stopMediaService() {
    VideoPlayerMediaService.clearPlayer();
    if (context != null) {
      try {
        Intent serviceIntent = new Intent(context, VideoPlayerMediaService.class);
        context.stopService(serviceIntent);
        Log.d("VideoPlayer", "MediaService stopped");
      } catch (Exception e) {
        Log.e("VideoPlayer", "Failed to stop MediaService: " + e.getMessage());
      }
    }
  }

  private void releaseMediaSession() {
    stopMediaService();
    if (mediaSession != null) {
      mediaSession.release();
      mediaSession = null;
    }
  }
}
