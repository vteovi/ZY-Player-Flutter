// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;

/**
 * 全局播放配置：由宿主 App 通过 {@code com.zy.player/system} 通道写入，供 ExoPlayer 构建时读取。
 *
 * <p>目前只有一项：是否强制软件解码。用于兼容部分机型硬件解码器在 H.264 High
 * Profile/1080p 上抛 {@code MediaCodecVideoRenderer error} 的情况。
 */
public final class PlaybackConfig {
  private PlaybackConfig() {}

  /** 是否强制使用软件解码器。由宿主 App 设置，默认关闭。 */
  public static volatile boolean forceSoftwareDecode = false;

  /**
   * 按当前配置返回 MediaCodec 选择器。
   *
   * <p>强制软件解码开启时返回「软件优先」选择器；否则沿用 ExoPlayer 默认（硬件优先）。
   */
  @NonNull
  public static MediaCodecSelector mediaCodecSelector() {
    return forceSoftwareDecode
        ? new SoftwareFirstMediaCodecSelector()
        : MediaCodecSelector.DEFAULT;
  }
}
