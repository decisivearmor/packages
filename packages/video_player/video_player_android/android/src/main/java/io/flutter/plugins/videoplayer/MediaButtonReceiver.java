// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.support.v4.media.session.PlaybackStateCompat;
import androidx.annotation.NonNull;

/**
 * Helper class for creating media button pending intents.
 */
public class MediaButtonReceiver {
  public static final String ACTION_MEDIA_BUTTON = "android.intent.action.MEDIA_BUTTON";
  
  public static PendingIntent buildMediaButtonPendingIntent(
      @NonNull Context context,
      long action) {
    Intent intent = new Intent(ACTION_MEDIA_BUTTON);
    intent.setComponent(new ComponentName(context, MediaButtonReceiver.class));
    intent.putExtra("android.intent.extra.KEY_EVENT", action);
    
    return PendingIntent.getBroadcast(
        context,
        (int) action,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
    );
  }
}