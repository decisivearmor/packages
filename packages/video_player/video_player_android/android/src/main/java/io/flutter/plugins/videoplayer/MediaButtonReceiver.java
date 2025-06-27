// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import androidx.annotation.NonNull;

/**
 * Broadcast receiver for handling media button events.
 */
public class MediaButtonReceiver extends BroadcastReceiver {
  public static final String ACTION_MEDIA_BUTTON = "android.intent.action.MEDIA_BUTTON";
  
  @Override
  public void onReceive(Context context, Intent intent) {
    if (ACTION_MEDIA_BUTTON.equals(intent.getAction())) {
      String action = intent.getStringExtra("action");
      // Handle media button action
      // This would typically be forwarded to the video player service
    }
  }
}