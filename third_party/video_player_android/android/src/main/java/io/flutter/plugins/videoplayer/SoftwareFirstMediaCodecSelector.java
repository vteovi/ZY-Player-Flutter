// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.media3.exoplayer.mediacodec.MediaCodecInfo;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil;
import java.util.ArrayList;
import java.util.List;

/**
 * 把软件解码器排到最前面的 {@link MediaCodecSelector}。
 *
 * <p>ExoPlayer 默认按硬件优先的顺序返回解码器。部分机型的硬件解码器在播放 H.264 High
 * Profile/1080p 时会抛 {@code MediaCodecVideoRenderer error}。开启「强制软件解码」后改用本选择器，
 * 让软件解码器（如 {@code c2.android.avc.decoder}）优先被选中，绕开有问题的硬解实现。
 */
public final class SoftwareFirstMediaCodecSelector implements MediaCodecSelector {

  @NonNull
  @Override
  public List<MediaCodecInfo> getDecoderInfos(
      @NonNull String mimeType,
      boolean requiresSecureDecoder,
      boolean requiresTunnelingDecoder)
      throws MediaCodecUtil.DecoderQueryException {
    List<MediaCodecInfo> infos =
        MediaCodecUtil.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder);
    if (infos.size() < 2) {
      return infos;
    }
    List<MediaCodecInfo> software = new ArrayList<>();
    List<MediaCodecInfo> hardware = new ArrayList<>();
    for (MediaCodecInfo info : infos) {
      if (info.softwareOnly) {
        software.add(info);
      } else {
        hardware.add(info);
      }
    }
    if (software.isEmpty()) {
      // 该格式没有软件解码器：保持原顺序（只能硬解）
      return infos;
    }
    List<MediaCodecInfo> reordered = new ArrayList<>(infos.size());
    reordered.addAll(software);
    reordered.addAll(hardware);
    return reordered;
  }
}
