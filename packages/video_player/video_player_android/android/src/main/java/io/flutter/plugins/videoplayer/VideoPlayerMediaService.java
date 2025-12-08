// Copyright 2013 The Flutter Authors
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
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.core.app.NotificationCompat;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.session.CommandButton;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import androidx.media3.session.MediaStyleNotificationHelper;
import androidx.media3.session.SessionCommand;
import androidx.media3.session.SessionResult;

import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

import java.io.InputStream;
import java.net.URL;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Media service for handling background playback and media notifications.
 */
@OptIn(markerClass = UnstableApi.class)
public class VideoPlayerMediaService extends MediaSessionService {
    private static final String TAG = "VideoPlayerMediaService";
    private static final String CHANNEL_ID = "video_player_media_channel";
    private static final int NOTIFICATION_ID = 1001;

    @Nullable
    private MediaSession mediaSession;

    @Nullable
    private static Player currentPlayer;

    @Nullable
    private static VideoPlayerEventCallbacks eventCallbacks;

    @Nullable
    private static VideoPlayerMediaService instance;

    private final ExecutorService artworkExecutor = Executors.newSingleThreadExecutor();
    private boolean isForegroundStarted = false;

    public static void setPlayer(@Nullable Player player) {
        currentPlayer = player;
        if (instance != null && player != null) {
            instance.updateSession(player);
        }
    }

    public static void setEventCallbacks(@Nullable VideoPlayerEventCallbacks callbacks) {
        eventCallbacks = callbacks;
    }

    public static void clearPlayer() {
        currentPlayer = null;
        if (instance != null) {
            instance.stopSelf();
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createNotificationChannel();

        // Must call startForeground immediately in onCreate when started via startForegroundService
        // Android requires this within a few seconds or the app will crash
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Media Playing")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .build();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
            isForegroundStarted = true;
            Log.d(TAG, "Started foreground in onCreate");
        }

        Log.d(TAG, "VideoPlayerMediaService created");
    }

    private void updateSession(@NonNull Player player) {
        if (mediaSession != null) {
            mediaSession.release();
        }

        // Custom commands for next/previous track
        SessionCommand nextCommand = new SessionCommand("nextTrack", Bundle.EMPTY);
        SessionCommand prevCommand = new SessionCommand("previousTrack", Bundle.EMPTY);

        mediaSession = new MediaSession.Builder(this, player)
            .setCallback(new MediaSession.Callback() {
                @NonNull
                @Override
                public MediaSession.ConnectionResult onConnect(
                        @NonNull MediaSession session,
                        @NonNull MediaSession.ControllerInfo controller) {
                    // Allow connections and add custom commands
                    return new MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                        .setAvailableSessionCommands(
                            MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                                .add(nextCommand)
                                .add(prevCommand)
                                .build())
                        .build();
                }

                @NonNull
                @Override
                public ListenableFuture<SessionResult> onCustomCommand(
                        @NonNull MediaSession session,
                        @NonNull MediaSession.ControllerInfo controller,
                        @NonNull SessionCommand customCommand,
                        @NonNull Bundle args) {
                    if ("nextTrack".equals(customCommand.customAction)) {
                        if (eventCallbacks != null) {
                            eventCallbacks.onNextTrackRequested();
                        }
                        return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                    } else if ("previousTrack".equals(customCommand.customAction)) {
                        if (eventCallbacks != null) {
                            eventCallbacks.onPreviousTrackRequested();
                        }
                        return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                    }
                    return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED));
                }
            })
            .build();

        Log.d(TAG, "MediaSession updated with new player");

        // Update notification with MediaStyle after session is created
        updateMediaStyleNotification();
    }

    private void updateMediaStyleNotification() {
        if (mediaSession == null) {
            return;
        }

        try {
            // Get the app's launch intent for the notification tap action
            Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
            PendingIntent pendingIntent = null;
            if (launchIntent != null) {
                pendingIntent = PendingIntent.getActivity(this, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            }

            // Build MediaStyle notification
            Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(getMediaTitle())
                .setContentText(getMediaArtist())
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentIntent(pendingIntent)
                .setStyle(new MediaStyleNotificationHelper.MediaStyle(mediaSession)
                    .setShowActionsInCompactView(0, 1, 2))
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .build();

            NotificationManager notificationManager = getSystemService(NotificationManager.class);
            if (notificationManager != null) {
                notificationManager.notify(NOTIFICATION_ID, notification);
            }
            Log.d(TAG, "Updated MediaStyle notification");
        } catch (Exception e) {
            Log.e(TAG, "Failed to update MediaStyle notification: " + e.getMessage());
        }
    }

    private String getMediaTitle() {
        if (currentPlayer != null && currentPlayer.getCurrentMediaItem() != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata.title != null) {
            return currentPlayer.getCurrentMediaItem().mediaMetadata.title.toString();
        }
        return "Media Playing";
    }

    private String getMediaArtist() {
        if (currentPlayer != null && currentPlayer.getCurrentMediaItem() != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata.artist != null) {
            return currentPlayer.getCurrentMediaItem().mediaMetadata.artist.toString();
        }
        return "";
    }

    @Override
    @Nullable
    public MediaSession onGetSession(@NonNull MediaSession.ControllerInfo controllerInfo) {
        return mediaSession;
    }

    @Override
    public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
        // startForeground is already called in onCreate, so we just need to update the session
        if (currentPlayer != null && mediaSession == null) {
            updateSession(currentPlayer);
        }
        return super.onStartCommand(intent, flags, startId);
    }

    @Override
    public void onDestroy() {
        if (mediaSession != null) {
            mediaSession.release();
            mediaSession = null;
        }
        artworkExecutor.shutdown();
        instance = null;
        Log.d(TAG, "VideoPlayerMediaService destroyed");
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(@Nullable Intent rootIntent) {
        Player player = mediaSession != null ? mediaSession.getPlayer() : null;
        if (player == null || !player.getPlayWhenReady() || player.getMediaItemCount() == 0) {
            stopSelf();
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Media Playback",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Controls for media playback");
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);

            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
}
