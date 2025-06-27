// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.media.app.NotificationMediaStyle;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaStyleNotificationHelper;
import com.google.common.util.concurrent.ListenableFuture;
import java.io.IOException;
import java.net.URL;
import java.util.concurrent.Executors;

/**
 * Handles MediaSession integration for video playback.
 * Provides media controls in notification and lock screen.
 */
@UnstableApi
public class MediaSessionHandler {
  private static final String CHANNEL_ID = "video_player_media_controls";
  private static final String CHANNEL_NAME = "Media Controls";
  private static final int NOTIFICATION_ID = 1001;
  
  private final Context context;
  private final NotificationManager notificationManager;
  private MediaSession mediaSession;
  private final String packageName;
  
  // Current metadata
  private String currentTitle;
  private String currentArtist;
  private String currentAlbum;
  private String currentArtworkUrl;
  private Bitmap currentArtwork;
  
  public MediaSessionHandler(@NonNull Context context) {
    this.context = context;
    this.packageName = context.getPackageName();
    this.notificationManager = 
        (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
    
    createNotificationChannel();
  }
  
  private void createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
          CHANNEL_ID,
          CHANNEL_NAME,
          NotificationManager.IMPORTANCE_LOW
      );
      channel.setDescription("Media playback controls");
      channel.setShowBadge(false);
      notificationManager.createNotificationChannel(channel);
    }
  }
  
  public void setPlayer(@Nullable ExoPlayer player) {
    if (player != null) {
      // Create MediaSession if not exists
      if (mediaSession == null) {
        mediaSession = new MediaSession.Builder(context, player)
            .setId("VideoPlayerMediaSession")
            .build();
      } else {
        // Update player for existing session
        mediaSession.setPlayer(player);
      }
      
      // Set up player listener for state changes
      player.addListener(new Player.Listener() {
        @Override
        public void onPlaybackStateChanged(int playbackState) {
          showNotification(player);
        }
        
        @Override
        public void onIsPlayingChanged(boolean isPlaying) {
          showNotification(player);
        }
        
        @Override
        public void onMediaMetadataChanged(androidx.media3.common.MediaMetadata mediaMetadata) {
          showNotification(player);
        }
      });
      
      showNotification(player);
    }
  }
  
  public void setMetadata(String title, String artist, String album, String artworkUrl) {
    this.currentTitle = title;
    this.currentArtist = artist;
    this.currentAlbum = album;
    this.currentArtworkUrl = artworkUrl;
    
    if (mediaSession != null && mediaSession.getPlayer() != null) {
      // Create MediaMetadata
      androidx.media3.common.MediaMetadata.Builder metadataBuilder = 
          new androidx.media3.common.MediaMetadata.Builder()
              .setTitle(title)
              .setArtist(artist)
              .setAlbumTitle(album);
      
      // Load artwork asynchronously
      if (artworkUrl != null && !artworkUrl.isEmpty()) {
        loadArtwork(artworkUrl, metadataBuilder);
      } else {
        mediaSession.getPlayer().setMediaMetadata(metadataBuilder.build());
      }
    }
  }
  
  private void loadArtwork(String url, androidx.media3.common.MediaMetadata.Builder metadataBuilder) {
    Executors.newSingleThreadExecutor().execute(() -> {
      try {
        URL artworkUrl = new URL(url);
        currentArtwork = BitmapFactory.decodeStream(artworkUrl.openStream());
        metadataBuilder.setArtworkData(bitmapToByteArray(currentArtwork), androidx.media3.common.MediaMetadata.PICTURE_TYPE_FRONT_COVER);
        if (mediaSession != null && mediaSession.getPlayer() != null) {
          mediaSession.getPlayer().setMediaMetadata(metadataBuilder.build());
        }
      } catch (IOException e) {
        // Failed to load artwork, use metadata without it
        if (mediaSession != null && mediaSession.getPlayer() != null) {
          mediaSession.getPlayer().setMediaMetadata(metadataBuilder.build());
        }
      }
    });
  }
  
  private byte[] bitmapToByteArray(Bitmap bitmap) {
    if (bitmap == null) return null;
    java.io.ByteArrayOutputStream stream = new java.io.ByteArrayOutputStream();
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream);
    return stream.toByteArray();
  }
  
  private void showNotification(@NonNull ExoPlayer player) {
    // Create intent for launching the app
    Intent intent = context.getPackageManager().getLaunchIntentForPackage(packageName);
    PendingIntent contentIntent = PendingIntent.getActivity(
        context, 
        0, 
        intent, 
        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
    );
    
    // Build the notification
    NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setContentTitle(currentTitle != null ? currentTitle : "Video Player")
        .setContentText(currentArtist != null ? currentArtist : "")
        .setContentIntent(contentIntent)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOnlyAlertOnce(true);
    
    if (currentArtwork != null) {
      builder.setLargeIcon(currentArtwork);
    }
    
    // Add MediaStyle
    if (mediaSession != null) {
      NotificationMediaStyle mediaStyle = new NotificationMediaStyle()
          .setShowActionsInCompactView(0, 1, 2);
      
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // For Android 13+, use the new MediaStyle with MediaSession
        builder.setStyle(MediaStyleNotificationHelper.MediaStyle(context, mediaSession)
            .setShowActionsInCompactView(0, 1, 2));
      } else {
        builder.setStyle(mediaStyle);
      }
    }
    
    // Add playback actions
    if (player.isPlaying()) {
      builder.addAction(
          android.R.drawable.ic_media_pause,
          "Pause",
          createMediaPendingIntent(context, PlaybackStateAction.PAUSE)
      );
    } else {
      builder.addAction(
          android.R.drawable.ic_media_play,
          "Play",
          createMediaPendingIntent(context, PlaybackStateAction.PLAY)
      );
    }
    
    Notification notification = builder.build();
    notificationManager.notify(NOTIFICATION_ID, notification);
  }
  
  private PendingIntent createMediaPendingIntent(Context context, PlaybackStateAction action) {
    Intent intent = new Intent(MediaButtonReceiver.ACTION_MEDIA_BUTTON);
    intent.setPackage(context.getPackageName());
    intent.putExtra("action", action.name());
    
    return PendingIntent.getBroadcast(
        context,
        action.ordinal(),
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
    );
  }
  
  private enum PlaybackStateAction {
    PLAY,
    PAUSE,
    PLAY_PAUSE,
    SEEK_TO
  }
  
  public void hideNotification() {
    notificationManager.cancel(NOTIFICATION_ID);
  }
  
  public void release() {
    hideNotification();
    if (mediaSession != null) {
      mediaSession.release();
      mediaSession = null;
    }
  }
  
  public MediaSession getMediaSession() {
    return mediaSession;
  }
}