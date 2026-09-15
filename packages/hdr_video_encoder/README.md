# hdr_video_encoder

Native HDR video encoder for the lyrics app's HDR export path. Encodes raw
sRGB RGBA8888 frames to an **HDR HEVC Main10 mp4** via `AVAssetWriter`
(iOS/macOS) and `MediaCodec` + `MediaMuxer` (Android).

The existing SDR export keeps using `flutter_quick_video_encoder`; this package
is only used by `HdrVideoExportService`.

## Pipeline

The HDR "glow" is a **pure per-pixel function of the SDR frame** — no separate
mask, one render pass. Per frame, per channel, natively:

```
s     = c / 255
lin   = srgbToLinear(s) * (1 + smoothstep(knee, 1, s) * (maxBoost - 1))
lin   = M_709_to_(2020|P3) * lin               // optional gamut matrix
E'    = OETF(lin)                              // HLG (default) or PQ
```

Because the glow depends only on how the pixel *looks*, two things identical in
SDR are identical in HDR — no artifacts from geometry/alpha (e.g. a
semi-transparent yellow over a yellow background stays invisible in HDR too).
`knee` (default 0.7) is the sRGB value where the glow starts ramping; `maxBoost`
(fixed `glowBoost` 4.0 in the UI) is the multiplier at white.

* **HLG**: SDR white (linear 1.0) maps to HLG scene-linear `0.26496` so it lands
  at signal 0.75 (BT.2408 reference white). Boost >~3.8× clips.
* **PQ**: SDR white → 203 nits (BT.2408), clamped to `maxContentLightLevel`
  (or 10000).

Output is tagged BT.2020 primaries + HLG/PQ transfer + BT.2020 matrix (or
BT.709 when `transfer: sdrRec709`).

## Device verification steps

In the animation screen: archive icon → dialog → **HDR** (vs SDR). Always HLG,
fixed glow 4.0. If the device has no HEVC Main10 encoder the HDR export throws
and lyrics silently falls back to SDR.

On macOS the written path is printed to the console (`HDR export written: ...`);
on device use the share sheet → Save to Files / Downloads, then:

```
ffprobe -show_streams file.mp4 | grep -E 'codec_name|profile|pix_fmt|color_'
```

Expect: `codec_name=hevc`, `profile=Main 10`, `pix_fmt=yuv420p10le`,
`color_primaries=bt2020`, `color_transfer=arib-std-b67` (HLG),
`color_space=bt2020nc`, `color_range=tv`. On an HDR display the text/shapes
glow; on SDR it must tone-map down, not clip.

## Status

* **Android — verified** on a Pixel 9 Pro (Android 17), HLG + boost mask.
  `ffprobe` confirms `hevc / Main 10 / yuv420p10le / bt2020 / arib-std-b67
  (HLG) / bt2020nc / tv`. The P010 fill goes through `MediaCodec.getInputImage()`
  and each plane's `rowStride`/`pixelStride` (a tightly-packed buffer shears the
  picture and misplaces chroma; writing Cr past `planes[1]`'s buffer throws).
* **iOS / macOS — compiles only, not yet run on device.** Need to confirm
  `AVAssetWriterInputPixelBufferAdaptor` + `64RGBAHalf` source + the CV colour
  attachments produce a correctly-tagged HDR file.

Open items: colour-science constants (OETF, 709→2020 matrix, limited-range
scaling) want unit tests against known sample values; HLG-vs-PQ default and PQ
mastering-display / CLL metadata; visual tuning of the HLG tone / glow amount.
