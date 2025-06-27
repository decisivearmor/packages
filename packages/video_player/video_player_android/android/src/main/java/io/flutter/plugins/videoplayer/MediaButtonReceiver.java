// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

/**
 * MediaButtonReceiver is now provided by androidx.media.session.MediaButtonReceiver
 * This class is kept for backward compatibility but delegates to the androidx version.
 */
public class MediaButtonReceiver extends androidx.media.session.MediaButtonReceiver {
  // All functionality is handled by the parent class
}