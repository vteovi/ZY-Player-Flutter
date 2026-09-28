// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.texture;

import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.Format;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import java.util.Objects;

public final class TextureExoPlayerEventListener extends ExoPlayerEventListener {
  private boolean surfaceProducerHandlesCropAndRotation;

  public TextureExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer,
      @NonNull VideoPlayerCallbacks events,
      boolean surfaceProducerHandlesCropAndRotation) {
    super(exoPlayer, events);
    this.surfaceProducerHandlesCropAndRotation = surfaceProducerHandlesCropAndRotation;
  }

  @Override
  protected void sendInitialized() {
    VideoSize videoSize = exoPlayer.getVideoSize();
    RotationDegrees rotationCorrection = RotationDegrees.ROTATE_0;
    int width = videoSize.width;
    int height = videoSize.height;
    if (width != 0 && height != 0) {
      // The video's own rotation, taken from the Format. This is independent of whether
      // Flutter has to rotate the preview itself.
      int videoRotation = 0;
      try {
        videoRotation = getRotationCorrectionFromFormat(exoPlayer);
      } catch (Exception e) {
        // No video Format available yet: treat as unrotated.
        videoRotation = 0;
      }

      if (surfaceProducerHandlesCropAndRotation) {
        // When the SurfaceTexture backend for Impeller is used, the preview should already
        // be correctly rotated.
        rotationCorrection = RotationDegrees.ROTATE_0;

        // FIX(zy-player): `VideoSize` reports the *pre-rotation* decode size. Callers (e.g.
        // video_player's `aspectRatio`) use this value as the on-screen shape of the video,
        // so it has to describe the display orientation instead. Without this swap a
        // portrait video encoded as 1920x1080 with a 90 degree rotation flag was reported as
        // landscape while its texture held a portrait frame - Flutter then laid the texture
        // out at 16:9 and stretched it sideways.
        if (videoRotation == 90 || videoRotation == 270) {
          width = videoSize.height;
          height = videoSize.width;
        }
      } else {
        // The video's Format also provides a rotation correction that may be used to
        // correct the rotation, so we try to use that to correct the video rotation
        // when the ImageReader backend for Impeller is used.
        try {
          rotationCorrection = RotationDegrees.fromDegrees(videoRotation);
        } catch (IllegalArgumentException e) {
          // Rotation correction other than 0, 90, 180, 270 reported by Format. Because this is
          // unexpected we apply no rotation correction.
          rotationCorrection = RotationDegrees.ROTATE_0;
        }
      }

      // NOTE(zy-player): in the ImageReader branch above the texture is *not* rotated by
      // the player, so `rotationCorrection` stays non-zero and the Dart side rotates the
      // preview itself. The width/height must therefore stay un-swapped here - swapping in
      // both branches would rotate the preview twice (portrait videos would come out
      // landscape again).
    }
    events.onInitialized(width, height, exoPlayer.getDuration(), rotationCorrection.getDegrees());
  }

  private RotationDegrees getRotationCorrectionFromUnappliedRotation(
      RotationDegrees unappliedRotationDegrees) {
    RotationDegrees rotationCorrection = RotationDegrees.ROTATE_0;

    // Rotating the video with ExoPlayer does not seem to be possible with a Surface,
    // so inform the Flutter code that the widget needs to be rotated to prevent
    // upside-down playback for videos with unappliedRotationDegrees of 180 (other orientations
    // work correctly without correction).
    if (unappliedRotationDegrees == RotationDegrees.ROTATE_180) {
      rotationCorrection = unappliedRotationDegrees;
    }

    return rotationCorrection;
  }

  @OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
  // A video's Format and its rotation degrees are unstable because they are not guaranteed
  // the same implementation across API versions. It is possible that this logic may need
  // revisiting should the implementation change across versions of the Exoplayer API.
  private int getRotationCorrectionFromFormat(ExoPlayer exoPlayer) {
    Format videoFormat = Objects.requireNonNull(exoPlayer.getVideoFormat());
    return videoFormat.rotationDegrees;
  }
}
