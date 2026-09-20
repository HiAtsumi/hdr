#import "HdrVideoEncoderPlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <math.h>
#import <string.h>

// ---------------------------------------------------------------------------
// Colour-science helpers (all operate on scene/display-linear RGB unless noted)
// KEEP IN SYNC with lib/src/hdr_color_math.dart (tested in
// test/hdr_color_math_test.dart against BT.2100 reference points).
// ---------------------------------------------------------------------------

// sRGB EOTF: gamma-encoded [0,1] -> linear [0,1]
static inline float srgbToLinear(float c) {
  if (c <= 0.04045f) return c / 12.92f;
  return powf((c + 0.055f) / 1.055f, 2.4f);
}

// Rec.709 linear -> Rec.2020 linear (BT.2087)
static inline void lin709ToLin2020(float *r, float *g, float *b) {
  float R = *r, G = *g, B = *b;
  *r = 0.62740f * R + 0.32930f * G + 0.04330f * B;
  *g = 0.06910f * R + 0.91950f * G + 0.01140f * B;
  *b = 0.01640f * R + 0.08800f * G + 0.89560f * B;
}

// Rec.709 linear -> Display-P3 linear (D65)
static inline void lin709ToLinP3(float *r, float *g, float *b) {
  float R = *r, G = *g, B = *b;
  *r = 0.822462f * R + 0.177538f * G + 0.0f * B;
  *g = 0.033194f * R + 0.966806f * G + 0.0f * B;
  *b = 0.017083f * R + 0.072397f * G + 0.910520f * B;
}

// PQ OETF (SMPTE ST 2084). L is display-linear normalised so 1.0 == 10000 nits.
static inline float pqOetf(float L) {
  if (L < 0.0f) L = 0.0f;
  const float m1 = 0.1593017578125f;
  const float m2 = 78.84375f;
  const float c1 = 0.8359375f;
  const float c2 = 18.8515625f;
  const float c3 = 18.6875f;
  float Lp = powf(L, m1);
  return powf((c1 + c2 * Lp) / (1.0f + c3 * Lp), m2);
}

// HLG OETF (BT.2100). E is scene-linear in [0,1] (1.0 == HLG peak).
static inline float hlgOetf(float E) {
  if (E < 0.0f) E = 0.0f;
  if (E > 1.0f) E = 1.0f;
  const float a = 0.17883277f;
  const float b = 0.28466892f;
  const float c = 0.55991073f;
  if (E <= 1.0f / 12.0f) return sqrtf(3.0f * E);
  return a * logf(12.0f * E - b) + c;
}

// smoothstep(edge0, edge1, x)
static inline float smoothstepf(float e0, float e1, float x) {
  if (e1 <= e0) return x < e0 ? 0.0f : 1.0f;
  float t = (x - e0) / (e1 - e0);
  if (t < 0.0f) t = 0.0f;
  if (t > 1.0f) t = 1.0f;
  return t * t * (3.0f - 2.0f * t);
}

// HDR glow factor for a pixel, driven by its "whiteness" = the min of its sRGB
// channels (0..1): 1.0 below knee, ramping to maxBoost at white. The min channel
// means a saturated colour with one maxed channel (pure amber, pure red) does
// NOT glow — only genuinely near-white pixels do. One factor per pixel so the
// glow only changes brightness, never hue.
static inline float glowFactorf(float whiteness, float knee, float maxBoost) {
  return 1.0f + smoothstepf(knee, 1.0f, whiteness) * (maxBoost - 1.0f);
}

// BT.2408 reference diffuse white in nits (SDR white maps here on the PQ
// path). Default only — overridable per-export via the "sdrWhiteNits" setup
// arg (self.sdrWhiteNits).
static const float kSdrWhiteNits = 203.0f;
// Scene-linear value that unboosted SDR white maps to on the HLG curve. Above
// the BT.2408 reference-white value (0.26496 = signal 0.75) at 0.5: non-glowing
// white lands HLG signal ~0.87 (~435 nits direct); reads brighter in an
// ffmpeg-style HLG->SDR preview. The phone's adaptive tone-map absorbs the
// anchor anyway. KEEP IN SYNC with hdr_color_math.dart / the Kotlin encoder.
static const float kHlgSdrWhiteScene = 0.5f;

typedef NS_ENUM(NSInteger, HdrTransferMode) { HdrTransferSdr709 = 0, HdrTransferHlg = 1, HdrTransferPq = 2 };
typedef NS_ENUM(NSInteger, HdrPrimariesMode) { HdrPrimaries709 = 0, HdrPrimariesP3 = 1, HdrPrimaries2020 = 2 };

// ---------------------------------------------------------------------------

@interface HdrVideoEncoderPlugin ()
@property(nonatomic) FlutterMethodChannel *channel;
@property(nonatomic) AVAssetWriter *writer;
@property(nonatomic) AVAssetWriterInput *videoInput;
@property(nonatomic) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic) int fps;
@property(nonatomic) int frameIdx;
@property(nonatomic) HdrTransferMode transfer;
@property(nonatomic) HdrPrimariesMode primaries;
@property(nonatomic) float maxBoost;
@property(nonatomic) float glowKnee;
@property(nonatomic) float saturation;
@property(nonatomic) float maxCll;   // nits, 0 == unset
@property(nonatomic) float maxFall;  // nits, 0 == unset
@property(nonatomic) float sdrWhiteNits;  // PQ anchor, default kSdrWhiteNits

// Audio passthrough for setup:/appendFrame:/finish: (the per-frame path —
// see convertVideo: for the equivalent on that pipeline). The source audio
// track is copied verbatim (no decode/re-encode) on its own queue, running
// concurrently with the Dart-driven video frame loop; finish: waits on
// audioGroup before finalizing the writer. All nil/unused when the source
// has no audio track (or setup: was called without inputPath).
@property(nonatomic) AVAssetReader *audioReader;
@property(nonatomic) AVAssetReaderTrackOutput *audioReaderOutput;
@property(nonatomic) AVAssetWriterInput *audioInput;
@property(nonatomic) dispatch_group_t audioGroup;

// State for convertVideo: (the single-call, no-Dart-round-trip pipeline —
// see that method for why it exists). atomic: convertFrameIdx/convertCancelRequested
// are written from the background conversion queue and read from the main
// queue (getConvertProgress / cancelConvertVideo), so plain ivars would risk
// torn reads; the default `atomic` property semantics are enough here since
// each is a single word read/written independently, never compound.
@property(atomic) int convertFrameIdx;
@property(atomic) int convertTotalFrames;
@property(atomic) BOOL convertCancelRequested;

// Latest live-preview thumbnail from an in-flight convertVideo: — small
// (long edge capped, see convertVideo:) so polling it periodically doesn't
// reintroduce the full-resolution-buffer-per-frame memory cost that
// convertVideo: exists to avoid. generation increments each time a new one
// is captured, so Dart can tell whether it's already shown this one.
@property(atomic) NSData *latestPreviewFrame;
@property(atomic) int latestPreviewWidth;
@property(atomic) int latestPreviewHeight;
@property(atomic) int latestPreviewGeneration;

@property(nonatomic) NSString *filepath;

- (void)stripDolbyVisionBoxFromFile:(NSString *)filepath;
- (void)relocateMoovBeforeMdatInFile:(NSString *)filepath;
@end

// CIE 1931 xy chromaticity of each primaries set's own R/G/B/white point (D65),
// used only to describe the "mastering display" in HDR static metadata — not
// used in the per-pixel colour maths.
static void HdrChromaticity(HdrPrimariesMode primaries, float *rx, float *ry, float *gx, float *gy,
                             float *bx, float *by, float *wx, float *wy) {
  switch (primaries) {
    case HdrPrimaries709:
      *rx = 0.640f; *ry = 0.330f; *gx = 0.300f; *gy = 0.600f; *bx = 0.150f; *by = 0.060f;
      break;
    case HdrPrimariesP3:
      *rx = 0.680f; *ry = 0.320f; *gx = 0.265f; *gy = 0.690f; *bx = 0.150f; *by = 0.060f;
      break;
    case HdrPrimaries2020:
    default:
      *rx = 0.708f; *ry = 0.292f; *gx = 0.170f; *gy = 0.797f; *bx = 0.131f; *by = 0.046f;
      break;
  }
  *wx = 0.3127f;
  *wy = 0.3290f;
}

// mastering_display_colour_volume() (SMPTE ST 2086), big-endian, in the byte
// layout Apple documents for kCMFormatDescriptionExtension_MasteringDisplayColorVolume:
// G,B,R chromaticity (x,y, each in 0.00002 units) then white point (x,y), then
// max/min display mastering luminance (0.0001 cd/m^2 units). A nominal
// 1000/0.0001 nit mastering display is declared (we have no real reference
// monitor) — only the primaries vary with [primaries].
static NSData *HdrMasteringDisplayColorVolumeData(HdrPrimariesMode primaries) {
  float rx, ry, gx, gy, bx, by, wx, wy;
  HdrChromaticity(primaries, &rx, &ry, &gx, &gy, &bx, &by, &wx, &wy);
  uint16_t chroma[8] = {
      (uint16_t)(gx * 50000.0f + 0.5f), (uint16_t)(gy * 50000.0f + 0.5f),
      (uint16_t)(bx * 50000.0f + 0.5f), (uint16_t)(by * 50000.0f + 0.5f),
      (uint16_t)(rx * 50000.0f + 0.5f), (uint16_t)(ry * 50000.0f + 0.5f),
      (uint16_t)(wx * 50000.0f + 0.5f), (uint16_t)(wy * 50000.0f + 0.5f),
  };
  NSMutableData *data = [NSMutableData dataWithCapacity:24];
  for (int i = 0; i < 8; i++) {
    uint16_t be = CFSwapInt16HostToBig(chroma[i]);
    [data appendBytes:&be length:2];
  }
  uint32_t maxLumBE = CFSwapInt32HostToBig((uint32_t)(1000.0f * 10000.0f + 0.5f));
  uint32_t minLumBE = CFSwapInt32HostToBig((uint32_t)(0.0001f * 10000.0f + 0.5f));
  [data appendBytes:&maxLumBE length:4];
  [data appendBytes:&minLumBE length:4];
  return data;
}

// content_light_level_info(), big-endian: MaxCLL, MaxFALL (cd/m^2, uint16 each)
// — matches kCMFormatDescriptionExtension_ContentLightLevelInfo.
static NSData *HdrContentLightLevelData(float maxCllNits, float maxFallNits) {
  uint16_t cll = CFSwapInt16HostToBig((uint16_t)(maxCllNits + 0.5f));
  uint16_t fall = CFSwapInt16HostToBig((uint16_t)(maxFallNits + 0.5f));
  NSMutableData *data = [NSMutableData dataWithCapacity:4];
  [data appendBytes:&cll length:2];
  [data appendBytes:&fall length:2];
  return data;
}

#pragma mark - Dolby Vision box stripping
//
// VideoToolbox tags every HDR (HLG/PQ) HEVC export with a Dolby Vision "dvvC"
// configuration box inside the video sample entry, declaring the stream
// Profile 8.4 (or equivalent) with rpu_present_flag=1 — even with
// HDRMetadataInsertionMode = "None" above (both here and in convertVideo:),
// which only suppresses the per-frame dynamic RPU payload, not this static
// container-level declaration. Verified by diffing the box tree of an iOS
// vs. an Android export of the same HLG clip in the beat project: identical
// hvcC/colr (primaries=9, transfer=18, matrix=9), but only the iOS file
// carries a dvvC box. YouTube's ingestion appears to treat that mismatched
// Dolby Vision declaration (RPU claimed present, none actually authored) as
// reason to fall back to SDR, even though every other player/SNS just
// ignores/tolerates it and reads the plain HLG signalling fine. Strip the
// box after writing so the file is unambiguous plain HLG/PQ HEVC, matching
// the Android encoder's output. KEEP IN SYNC with the beat/lyrics copies of
// this file (both pipelines here — setup:/appendFrame:/finish: AND
// convertVideo: — call stripDolbyVisionBoxFromFile: on success).

static uint32_t ReadBE32(NSData *data, NSUInteger offset) {
  const uint8_t *p = (const uint8_t *)data.bytes + offset;
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void WriteBE32(NSMutableData *data, NSUInteger offset, uint32_t value) {
  uint8_t *p = (uint8_t *)data.mutableBytes + offset;
  p[0] = (value >> 24) & 0xFF;
  p[1] = (value >> 16) & 0xFF;
  p[2] = (value >> 8) & 0xFF;
  p[3] = value & 0xFF;
}

// Finds the first child box of `type` within [start, end) of `data` (32-bit
// sizes only — moov and everything under it are small and never use a
// 64-bit "largesize" box in AVAssetWriter's output). Returns NO if not found
// or the box tree looks malformed, rather than reading out of bounds.
static BOOL FindBox(NSData *data, NSUInteger start, NSUInteger end, const char *type,
                     NSUInteger *outOffset, NSUInteger *outSize) {
  NSUInteger offset = start;
  while (offset + 8 <= end) {
    uint32_t size = ReadBE32(data, offset);
    if (size < 8 || offset + size > end) return NO;
    if (memcmp((const uint8_t *)data.bytes + offset + 4, type, 4) == 0) {
      *outOffset = offset;
      *outSize = size;
      return YES;
    }
    offset += size;
  }
  return NO;
}

// Removes [rangeStart, rangeStart+len) from `data` and subtracts `len` from
// the 32-bit big-endian size field at the start of every box in
// `ancestorOffsets` (each of which contains the removed range).
static void RemoveRangeAndShrinkAncestors(NSMutableData *data, NSUInteger rangeStart,
                                           NSUInteger len, NSArray<NSNumber *> *ancestorOffsets) {
  [data replaceBytesInRange:NSMakeRange(rangeStart, len) withBytes:NULL length:0];
  for (NSNumber *off in ancestorOffsets) {
    NSUInteger o = off.unsignedIntegerValue;
    uint32_t size = ReadBE32(data, o);
    WriteBE32(data, o, size - (uint32_t)len);
  }
}

static uint64_t ReadBE64(NSData *data, NSUInteger offset) {
  const uint8_t *p = (const uint8_t *)data.bytes + offset;
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = (v << 8) | p[i];
  return v;
}

static void WriteBE64(NSMutableData *data, NSUInteger offset, uint64_t value) {
  uint8_t *p = (uint8_t *)data.mutableBytes + offset;
  for (int i = 7; i >= 0; i--) {
    p[i] = value & 0xFF;
    value >>= 8;
  }
}

// Like FindBox, but collects every matching child box's (offset, size)
// instead of stopping at the first one — a moov can have more than one
// `trak` (e.g. video + audio, which this project's finish:/convertVideo:
// pipelines both can produce via audio passthrough).
static void FindAllBoxes(NSData *data, NSUInteger start, NSUInteger end, const char *type,
                          NSMutableArray<NSValue *> *outRanges) {
  NSUInteger offset = start;
  while (offset + 8 <= end) {
    uint32_t size = ReadBE32(data, offset);
    if (size < 8 || offset + size > end) return;
    if (memcmp((const uint8_t *)data.bytes + offset + 4, type, 4) == 0) {
      [outRanges addObject:[NSValue valueWithRange:NSMakeRange(offset, size)]];
    }
    offset += size;
  }
}

// Adds `delta` to every chunk offset in every track's `stco`/`co64` box
// inside `moov` (in place, `moov` starting at data offset 0). Each entry is
// an absolute byte offset of sample data inside `mdat`; called after moov
// is relocated to sit earlier in the file, so every one needs to point
// `delta` bytes further in. Returns NO (leaving `moov` unmodified as far as
// the caller can rely on) if the track structure isn't what's expected,
// so the caller can bail rather than write a corrupt file.
static BOOL ShiftAllChunkOffsets(NSMutableData *moov, uint32_t delta) {
  NSMutableArray<NSValue *> *traks = [NSMutableArray array];
  FindAllBoxes(moov, 8, moov.length, "trak", traks);
  if (traks.count == 0) return NO;
  for (NSValue *trakVal in traks) {
    NSRange trakRange = trakVal.rangeValue;
    NSUInteger mdiaOff, mdiaSize, minfOff, minfSize, stblOff, stblSize;
    if (!FindBox(moov, trakRange.location + 8, trakRange.location + trakRange.length, "mdia",
                 &mdiaOff, &mdiaSize)) {
      return NO;
    }
    if (!FindBox(moov, mdiaOff + 8, mdiaOff + mdiaSize, "minf", &minfOff, &minfSize)) return NO;
    if (!FindBox(moov, minfOff + 8, minfOff + minfSize, "stbl", &stblOff, &stblSize)) return NO;

    NSUInteger stcoOff, stcoSize;
    if (FindBox(moov, stblOff + 8, stblOff + stblSize, "stco", &stcoOff, &stcoSize)) {
      NSUInteger entryCountOff = stcoOff + 12;
      uint32_t entryCount = ReadBE32(moov, entryCountOff);
      NSUInteger p = entryCountOff + 4;
      if (p + (NSUInteger)entryCount * 4 > stcoOff + stcoSize) return NO;
      for (uint32_t i = 0; i < entryCount; i++, p += 4) {
        WriteBE32(moov, p, ReadBE32(moov, p) + delta);
      }
      continue;
    }
    NSUInteger co64Off, co64Size;
    if (FindBox(moov, stblOff + 8, stblOff + stblSize, "co64", &co64Off, &co64Size)) {
      NSUInteger entryCountOff = co64Off + 12;
      uint32_t entryCount = ReadBE32(moov, entryCountOff);
      NSUInteger p = entryCountOff + 4;
      if (p + (NSUInteger)entryCount * 8 > co64Off + co64Size) return NO;
      for (uint32_t i = 0; i < entryCount; i++, p += 8) {
        WriteBE64(moov, p, ReadBE64(moov, p) + delta);
      }
      continue;
    }
    return NO;  // neither stco nor co64 — not the sample-table shape we expect, bail
  }
  return YES;
}

@implementation HdrVideoEncoderPlugin

- (void)stripDolbyVisionBoxFromFile:(NSString *)filepath {
  if (filepath.length == 0) return;
  @try {
    NSFileHandle *fh = [NSFileHandle fileHandleForUpdatingAtPath:filepath];
    if (!fh) return;
    unsigned long long fileSize = [fh seekToEndOfFile];

    // Walk top-level boxes with tiny 8/16-byte reads to locate `moov` — mdat
    // can be hundreds of MB to several GB and must never be loaded into
    // memory. Handles the 64-bit "largesize" box form so a large mdat is
    // skipped correctly rather than misread as a small one.
    unsigned long long offset = 0;
    unsigned long long moovOffset = 0, moovSize = 0;
    BOOL foundMoov = NO;
    while (offset + 8 <= fileSize) {
      [fh seekToFileOffset:offset];
      NSData *header = [fh readDataOfLength:8];
      if (header.length < 8) break;
      uint32_t size32 = ReadBE32(header, 0);
      char type[5] = {0};
      memcpy(type, (const uint8_t *)header.bytes + 4, 4);
      unsigned long long boxSize;
      unsigned long long headerLen = 8;
      if (size32 == 1) {
        NSData *ext = [fh readDataOfLength:8];
        if (ext.length < 8) break;
        uint64_t hi = ReadBE32(ext, 0);
        uint64_t lo = ReadBE32(ext, 4);
        boxSize = (hi << 32) | lo;
        headerLen = 16;
      } else if (size32 == 0) {
        boxSize = fileSize - offset;
      } else {
        boxSize = size32;
      }
      if (boxSize < headerLen) break;
      if (strcmp(type, "moov") == 0) {
        moovOffset = offset;
        moovSize = boxSize;
        foundMoov = YES;
        break;
      }
      offset += boxSize;
    }
    if (!foundMoov || moovOffset + moovSize > fileSize) {
      [fh closeFile];
      return;
    }

    // Read moov plus whatever (normally empty) tail follows it, patch in
    // memory, and rewrite just that span — mdat, which precedes moov in this
    // writer's output, is never touched.
    [fh seekToFileOffset:moovOffset];
    NSMutableData *tail = [[fh readDataToEndOfFile] mutableCopy];
    [fh closeFile];
    if (!tail || tail.length != fileSize - moovOffset) return;

    NSUInteger trakOff, trakSize, mdiaOff, mdiaSize, minfOff, minfSize, stblOff, stblSize,
        stsdOff, stsdSize;
    if (!FindBox(tail, 8, (NSUInteger)moovSize, "trak", &trakOff, &trakSize)) return;
    if (!FindBox(tail, trakOff + 8, trakOff + trakSize, "mdia", &mdiaOff, &mdiaSize)) return;
    if (!FindBox(tail, mdiaOff + 8, mdiaOff + mdiaSize, "minf", &minfOff, &minfSize)) return;
    if (!FindBox(tail, minfOff + 8, minfOff + minfSize, "stbl", &stblOff, &stblSize)) return;
    if (!FindBox(tail, stblOff + 8, stblOff + stblSize, "stsd", &stsdOff, &stsdSize)) return;

    // stsd is a FullBox: 4-byte version/flags + 4-byte entry_count before the
    // sample entries.
    NSUInteger sampleEntryStart = stsdOff + 8 + 8;
    NSUInteger entryOff = 0, entrySize = 0;
    BOOL foundEntry =
        FindBox(tail, sampleEntryStart, stsdOff + stsdSize, "hvc1", &entryOff, &entrySize);
    if (!foundEntry) {
      foundEntry = FindBox(tail, sampleEntryStart, stsdOff + stsdSize, "hev1", &entryOff, &entrySize);
    }
    if (!foundEntry) return;

    // VisualSampleEntry: 8-byte box header + 78 fixed bytes, then child
    // boxes (hvcC, colr, dvvC/dvcC, ...).
    NSUInteger childStart = entryOff + 8 + 78;
    NSUInteger dvOff = 0, dvSize = 0;
    BOOL foundDv = FindBox(tail, childStart, entryOff + entrySize, "dvvC", &dvOff, &dvSize);
    if (!foundDv) {
      foundDv = FindBox(tail, childStart, entryOff + entrySize, "dvcC", &dvOff, &dvSize);
    }
    if (!foundDv) return;  // nothing to strip (e.g. SDR export)

    NSArray<NSNumber *> *ancestors =
        @[ @(entryOff), @(stsdOff), @(stblOff), @(minfOff), @(mdiaOff), @(trakOff), @(0) ];
    RemoveRangeAndShrinkAncestors(tail, dvOff, dvSize, ancestors);

    NSFileHandle *wfh = [NSFileHandle fileHandleForWritingAtPath:filepath];
    if (!wfh) return;
    [wfh seekToFileOffset:moovOffset];
    [wfh writeData:tail];
    unsigned long long newFileSize = moovOffset + tail.length;
    [wfh truncateFileAtOffset:newFileSize];
    [wfh closeFile];
  } @catch (NSException *e) {
    NSLog(@"[hdr_video_encoder] stripDolbyVisionBoxFromFile failed: %@", e.reason);
  }
}

#pragma mark - moov relocation ("faststart")
//
// AVAssetWriter always appends `moov` after `mdat` (it can't know the final
// sample tables until every frame has been written), giving files the shape
// ftyp + mdat + moov. That's fine for local playback/AVFoundation, which
// seeks freely, but some ingestion pipelines a shared file is handed to may
// read front-to-back and finish their analysis — including whatever decides
// HDR-ness, which lives inside `moov` — before ever reaching the tail. This
// moves `moov` to sit right after `ftyp` and before `mdat` ("faststart"),
// matching the shape most camera/editing pipelines already produce. Every
// chunk offset stored in every track's `stco`/`co64` is an absolute file
// offset into `mdat`, so each one is bumped forward by moov's size once it
// moves earlier in the file (mdat's own bytes, and moov's own box size, are
// untouched — only those offset integers change). Requires the file to be
// exactly ftyp + mdat + moov with nothing after moov (AVAssetWriter's normal
// non-fragmented output shape); bails without touching the file otherwise.
// `mdat` (hundreds of MB to several GB) is streamed to a temp file in
// chunks, never loaded into memory. Handles multiple tracks (this project's
// finish:/convertVideo: can both mux in an audio track via passthrough), see
// ShiftAllChunkOffsets. KEEP IN SYNC with the beat/lyrics/withmap projects'
// copies of this file.
- (void)relocateMoovBeforeMdatInFile:(NSString *)filepath {
  if (filepath.length == 0) return;
  NSString *tmpPath = [filepath stringByAppendingString:@".faststart.tmp"];
  @try {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:filepath];
    if (!fh) return;
    unsigned long long fileSize = [fh seekToEndOfFile];
    [fh seekToFileOffset:0];

    NSData *ftypHeader = [fh readDataOfLength:8];
    if (ftypHeader.length < 8 || memcmp((const uint8_t *)ftypHeader.bytes + 4, "ftyp", 4) != 0) {
      [fh closeFile];
      return;
    }
    uint32_t ftypSize = ReadBE32(ftypHeader, 0);
    if (ftypSize < 8 || ftypSize > fileSize) {
      [fh closeFile];
      return;
    }
    unsigned long long mdatOffset = ftypSize;

    [fh seekToFileOffset:mdatOffset];
    NSData *mdatHeader = [fh readDataOfLength:8];
    if (mdatHeader.length < 8 || memcmp((const uint8_t *)mdatHeader.bytes + 4, "mdat", 4) != 0) {
      [fh closeFile];
      return;
    }
    uint32_t mdatSize32 = ReadBE32(mdatHeader, 0);
    unsigned long long mdatSize;
    if (mdatSize32 == 1) {
      NSData *ext = [fh readDataOfLength:8];
      if (ext.length < 8) {
        [fh closeFile];
        return;
      }
      mdatSize = ((uint64_t)ReadBE32(ext, 0) << 32) | ReadBE32(ext, 4);
    } else if (mdatSize32 == 0) {
      [fh closeFile];  // extends to EOF -> no moov after it, not our expected shape
      return;
    } else {
      mdatSize = mdatSize32;
    }
    unsigned long long moovOffset = mdatOffset + mdatSize;
    if (moovOffset >= fileSize) {
      [fh closeFile];
      return;
    }

    [fh seekToFileOffset:moovOffset];
    NSMutableData *moov = [[fh readDataToEndOfFile] mutableCopy];
    [fh closeFile];
    if (!moov || moov.length != fileSize - moovOffset) return;
    if (moov.length < 8 || ReadBE32(moov, 0) != moov.length ||
        memcmp((const uint8_t *)moov.bytes + 4, "moov", 4) != 0) {
      return;  // trailing content after moov, or malformed — bail, leave file untouched
    }
    if (moov.length > UINT32_MAX) return;  // moov is always small; refuse to touch anything this odd

    if (!ShiftAllChunkOffsets(moov, (uint32_t)moov.length)) return;

    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    if (![[NSFileManager defaultManager] createFileAtPath:tmpPath contents:nil attributes:nil]) {
      return;
    }
    NSFileHandle *wfh = [NSFileHandle fileHandleForWritingAtPath:tmpPath];
    NSFileHandle *rfh = [NSFileHandle fileHandleForReadingAtPath:filepath];
    if (!wfh || !rfh) {
      [wfh closeFile];
      [rfh closeFile];
      [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
      return;
    }

    [rfh seekToFileOffset:0];
    [wfh writeData:[rfh readDataOfLength:(NSUInteger)ftypSize]];  // ftyp, unchanged
    [wfh writeData:moov];                                         // moov, patched, now second
    [rfh seekToFileOffset:mdatOffset];
    const NSUInteger kCopyChunk = 4 * 1024 * 1024;
    unsigned long long remaining = mdatSize;
    while (remaining > 0) {
      @autoreleasepool {
        NSUInteger n = remaining < kCopyChunk ? (NSUInteger)remaining : kCopyChunk;
        NSData *chunk = [rfh readDataOfLength:n];
        if (chunk.length == 0) break;
        [wfh writeData:chunk];
        remaining -= chunk.length;
      }
    }
    [rfh closeFile];
    [wfh closeFile];
    if (remaining != 0) {
      [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
      return;  // short read copying mdat — leave the original file untouched
    }

    NSError *moveErr = nil;
    if (![[NSFileManager defaultManager] replaceItemAtURL:[NSURL fileURLWithPath:filepath]
                                              withItemAtURL:[NSURL fileURLWithPath:tmpPath]
                                             backupItemName:nil
                                                    options:0
                                           resultingItemURL:nil
                                                      error:&moveErr]) {
      NSLog(@"[hdr_video_encoder] relocateMoovBeforeMdatInFile replace failed: %@", moveErr);
      [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    }
  } @catch (NSException *e) {
    NSLog(@"[hdr_video_encoder] relocateMoovBeforeMdatInFile failed: %@", e.reason);
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
  }
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
#if TARGET_OS_OSX
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"hdr_video_encoder/methods"
                                  binaryMessenger:registrar.messenger];
#else
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"hdr_video_encoder/methods"
                                  binaryMessenger:[registrar messenger]];
#endif
  HdrVideoEncoderPlugin *instance = [[HdrVideoEncoderPlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  @try {
    if ([@"probe" isEqualToString:call.method]) {
      [self probe:result];
    } else if ([@"setup" isEqualToString:call.method]) {
      [self setup:call.arguments result:result];
    } else if ([@"appendFrame" isEqualToString:call.method]) {
      [self appendFrame:call.arguments result:result];
    } else if ([@"finish" isEqualToString:call.method]) {
      [self finish:result];
    } else if ([@"cancel" isEqualToString:call.method]) {
      [self cancelEncoding];
      result(nil);
    } else if ([@"convertVideo" isEqualToString:call.method]) {
      [self convertVideo:call.arguments result:result];
    } else if ([@"getConvertProgress" isEqualToString:call.method]) {
      result(@{@"frameIdx" : @(self.convertFrameIdx), @"totalFrames" : @(self.convertTotalFrames)});
    } else if ([@"cancelConvertVideo" isEqualToString:call.method]) {
      self.convertCancelRequested = YES;
      result(nil);
    } else if ([@"getLatestPreviewFrame" isEqualToString:call.method]) {
      NSData *frame = self.latestPreviewFrame;
      if (!frame) {
        result(nil);
      } else {
        result(@{
          @"generation" : @(self.latestPreviewGeneration),
          @"width" : @(self.latestPreviewWidth),
          @"height" : @(self.latestPreviewHeight),
          @"bytes" : [FlutterStandardTypedData typedDataWithBytes:frame],
        });
      }
    } else {
      result(FlutterMethodNotImplemented);
    }
  } @catch (NSException *e) {
    result([FlutterError errorWithCode:@"hdrEncoderException"
                              message:e.reason
                              details:[[e callStackSymbols] componentsJoinedByString:@"\n"]]);
  }
}

- (void)probe:(FlutterResult)result {
  // HEVC Main10 hardware encoding is available on every iOS device and Mac that
  // runs our minimum OS (iOS 15 / macOS 12). Confirm an HEVC encoder exists.
  BOOL hasHevc = NO;
  CFArrayRef encoders = NULL;
  if (VTCopyVideoEncoderList(NULL, &encoders) == noErr && encoders) {
    for (CFIndex i = 0; i < CFArrayGetCount(encoders); i++) {
      CFDictionaryRef enc = CFArrayGetValueAtIndex(encoders, i);
      CFNumberRef codecType = CFDictionaryGetValue(enc, kVTVideoEncoderList_CodecType);
      int32_t v = 0;
      if (codecType && CFNumberGetValue(codecType, kCFNumberSInt32Type, &v) &&
          v == kCMVideoCodecType_HEVC) {
        hasHevc = YES;
        break;
      }
    }
    CFRelease(encoders);
  }
  result(@{
    @"supported" : @(hasHevc),
    @"reason" : hasHevc ? [NSNull null] : @"no HEVC encoder on this device",
  });
}

// Aborts an in-flight setup:/appendFrame: export: stops the audio passthrough,
// cancels the AVAssetWriter (which also deletes its partial output), drops the
// input/adaptor/pixel-buffer pool, and removes the partial file. No-op when
// nothing is running. Also called at the top of setup: so an export that was
// never finished can't leak into the next one. (convertVideo: has its own
// cancel path — cancelConvertVideo — and tears itself down.)
- (void)cancelEncoding {
  AVAssetWriter *w = self.writer;
  if (!w) return; // nothing in flight (never set up, or already finished)
  if (w.status == AVAssetWriterStatusWriting) {
    // Same order as finish: — end the reader and the video input first so the
    // audio pump runs dry and calls markAsFinished on its own queue, then wait
    // for it (bounded) before cancelling the writer.
    [self.audioReader cancelReading];
    [self.videoInput markAsFinished];
    if (self.audioGroup) {
      dispatch_group_wait(self.audioGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    [w cancelWriting];
  }
  [self.audioReader cancelReading];
  self.audioReader = nil;
  self.audioReaderOutput = nil;
  self.audioInput = nil;
  self.audioGroup = nil;
  self.writer = nil;
  self.videoInput = nil;
  self.adaptor = nil;
  if (self.filepath.length > 0) {
    [[NSFileManager defaultManager] removeItemAtPath:self.filepath error:nil];
  }
}

- (void)setup:(NSDictionary *)args result:(FlutterResult)result {
  if (self.writer) [self cancelEncoding];
  self.width = [args[@"width"] intValue];
  self.height = [args[@"height"] intValue];
  self.fps = [args[@"fps"] intValue];
  self.frameIdx = 0;
  int bitrate = [args[@"videoBitrate"] intValue];
  NSString *filepath = args[@"filepath"];
  self.filepath = filepath;
  NSString *transferStr = args[@"transfer"];
  NSString *primariesStr = args[@"primaries"];
  self.maxBoost = [args[@"maxBoost"] floatValue];
  if (self.maxBoost < 1.0f) self.maxBoost = 1.0f;
  self.glowKnee = args[@"glowKnee"] ? [args[@"glowKnee"] floatValue] : 0.7f;
  self.saturation = args[@"saturation"] ? [args[@"saturation"] floatValue] : 1.0f;
  if (self.saturation <= 0.0f) self.saturation = 1.0f;
  self.maxCll = args[@"maxContentLightLevel"] == [NSNull null] || args[@"maxContentLightLevel"] == nil
                   ? 0.0f
                   : [args[@"maxContentLightLevel"] floatValue];
  self.maxFall = args[@"maxFrameAverageLightLevel"] == [NSNull null] ||
                         args[@"maxFrameAverageLightLevel"] == nil
                     ? 0.0f
                     : [args[@"maxFrameAverageLightLevel"] floatValue];
  self.sdrWhiteNits = args[@"sdrWhiteNits"] == [NSNull null] || args[@"sdrWhiteNits"] == nil
                          ? kSdrWhiteNits
                          : [args[@"sdrWhiteNits"] floatValue];

  self.transfer = HdrTransferHlg;
  if ([transferStr isEqualToString:@"sdrRec709"]) self.transfer = HdrTransferSdr709;
  else if ([transferStr isEqualToString:@"pq"]) self.transfer = HdrTransferPq;

  self.primaries = HdrPrimaries2020;
  if ([primariesStr isEqualToString:@"rec709"]) self.primaries = HdrPrimaries709;
  else if ([primariesStr isEqualToString:@"displayP3"]) self.primaries = HdrPrimariesP3;
  // sdrRec709 transfer is only meaningful with 709 primaries
  if (self.transfer == HdrTransferSdr709) self.primaries = HdrPrimaries709;

  NSError *error = nil;
  NSURL *url = [NSURL fileURLWithPath:filepath];
  if ([[NSFileManager defaultManager] fileExistsAtPath:filepath]) {
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  }
  self.writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
  if (error) {
    result([FlutterError errorWithCode:@"writerInit" message:error.localizedDescription details:nil]);
    return;
  }

  // Colour tags shared by the output settings and each pixel buffer.
  NSString *primariesTag;
  NSString *matrixTag;
  switch (self.primaries) {
    case HdrPrimaries709:
      primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2;
      matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimariesP3:
      primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_P3_D65;
      matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimaries2020:
    default:
      primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020;
      matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020;
      break;
  }
  NSString *transferTag;
  switch (self.transfer) {
    case HdrTransferSdr709:
      transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2;
      break;
    case HdrTransferPq:
      transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
      break;
    case HdrTransferHlg:
    default:
      transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG;
      break;
  }

  NSMutableDictionary *compression = [@{
    AVVideoAverageBitRateKey : @(bitrate),
    AVVideoProfileLevelKey : (__bridge NSString *)kVTProfileLevel_HEVC_Main10_AutoLevel,
    // VideoToolbox otherwise auto-injects Dolby Vision Profile 8.4 dynamic
    // metadata (an RPU) into the HEVC stream. DoVi players then run that
    // (conservative, machine-generated) trim pass over our HLG base layer, which
    // reads as darker / desaturated vs. the plain HLG. We author our own static
    // colour tags and want the base layer shown as-is, so disable it.
    // kVTCompressionPropertyKey_HDRMetadataInsertionMode = "None".
    @"HDRMetadataInsertionMode" : @"None",
  } mutableCopy];

  NSDictionary *colorProps = @{
    AVVideoColorPrimariesKey : primariesTag,
    AVVideoTransferFunctionKey : transferTag,
    AVVideoYCbCrMatrixKey : matrixTag,
  };

  NSDictionary *videoSettings = @{
    AVVideoCodecKey : AVVideoCodecTypeHEVC,
    AVVideoWidthKey : @(self.width),
    AVVideoHeightKey : @(self.height),
    AVVideoCompressionPropertiesKey : compression,
    AVVideoColorPropertiesKey : colorProps,
  };

  // PQ is an absolute-luminance signal: without static metadata declaring the
  // content's actual peak/average brightness, players commonly assume the
  // nominal PQ ceiling (10000 nits) and apply a generic tone-map tuned for
  // that — crushing contrast on content that's actually only ~200-800 nits
  // (washed-out/"foggy" look). HLG doesn't need this (its OOTF is relative to
  // a declared nominal peak, not absolute). AVAssetWriterInput has no
  // dedicated HDR-metadata setting; the documented way to attach it is a
  // sourceFormatHint carrying these format description extensions.
  CMFormatDescriptionRef sourceFormatHint = NULL;
  if (self.transfer == HdrTransferPq) {
    float maxCllNits = self.maxCll > 0.0f ? self.maxCll : self.sdrWhiteNits;
    float maxFallNits = self.maxFall > 0.0f ? self.maxFall : self.sdrWhiteNits;
    NSDictionary *extensions = @{
      (__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries : primariesTag,
      (__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction : transferTag,
      (__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix : matrixTag,
      (__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume :
          HdrMasteringDisplayColorVolumeData(self.primaries),
      (__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo :
          HdrContentLightLevelData(maxCllNits, maxFallNits),
    };
    CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_HEVC, self.width,
                                    self.height, (__bridge CFDictionaryRef)extensions,
                                    &sourceFormatHint);
  }

  self.videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                  outputSettings:videoSettings
                                                sourceFormatHint:sourceFormatHint];
  if (sourceFormatHint) CFRelease(sourceFormatHint);
  self.videoInput.expectsMediaDataInRealTime = NO;

  // HDR path uses a half-float RGBA source buffer (we apply the OETF ourselves,
  // VideoToolbox does RGB->YCbCr + 10-bit encode). The SDR checkpoint path uses
  // plain BGRA and lets VideoToolbox upconvert to 10-bit.
  OSType srcFormat = (self.transfer == HdrTransferSdr709) ? kCVPixelFormatType_32BGRA
                                                          : kCVPixelFormatType_64RGBAHalf;
  NSDictionary *srcAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(srcFormat),
    (id)kCVPixelBufferWidthKey : @(self.width),
    (id)kCVPixelBufferHeightKey : @(self.height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  self.adaptor = [AVAssetWriterInputPixelBufferAdaptor
      assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoInput
                                 sourcePixelBufferAttributes:srcAttrs];

  if (![self.writer canAddInput:self.videoInput]) {
    result([FlutterError errorWithCode:@"addInput" message:@"cannot add video input" details:nil]);
    return;
  }
  [self.writer addInput:self.videoInput];

  if (![self.writer startWriting]) {
    result([FlutterError errorWithCode:@"startWriting"
                              message:self.writer.error.localizedDescription
                              details:nil]);
    return;
  }
  [self.writer startSessionAtSourceTime:kCMTimeZero];

  NSString *inputPath = args[@"inputPath"];
  if ([inputPath isKindOfClass:[NSString class]] && inputPath.length > 0) {
    [self beginAudioPassthroughFromInputPath:inputPath];
  }

  result(nil);
}

// Sets up self.audioReader/audioReaderOutput/audioInput and starts copying
// the source's audio track (verbatim, no decode/re-encode) into self.writer
// on its own serial queue via requestMediaDataWhenReadyOnQueue:, running
// concurrently with the Dart-driven appendFrame: video loop. No-ops (leaves
// self.audioInput nil) if the source has no audio track, or if the writer/
// reader can't be wired up — a silent output is preferable to failing the
// whole conversion over an audio problem.
- (void)beginAudioPassthroughFromInputPath:(NSString *)inputPath {
  NSURL *inURL = [NSURL fileURLWithPath:inputPath];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inURL options:nil];
  AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
  if (!audioTrack) return;

  NSError *readerError = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
  if (readerError || !reader) return;
  AVAssetReaderTrackOutput *readerOutput =
      [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:nil];
  if (![reader canAddOutput:readerOutput]) return;
  [reader addOutput:readerOutput];
  if (![reader startReading]) return;

  AVAssetWriterInput *audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                                  outputSettings:nil];
  audioInput.expectsMediaDataInRealTime = NO;
  if (![self.writer canAddInput:audioInput]) {
    [reader cancelReading];
    return;
  }
  [self.writer addInput:audioInput];

  self.audioReader = reader;
  self.audioReaderOutput = readerOutput;
  self.audioInput = audioInput;
  self.audioGroup = dispatch_group_create();
  dispatch_group_enter(self.audioGroup);

  dispatch_queue_t audioQueue = dispatch_queue_create("hdr_video_encoder.audio", DISPATCH_QUEUE_SERIAL);
  dispatch_group_t group = self.audioGroup;
  __weak typeof(self) weakSelf = self;
  __block BOOL left = NO;
  [audioInput requestMediaDataWhenReadyOnQueue:audioQueue
                                     usingBlock:^{
                                       typeof(self) strongSelf = weakSelf;
                                       while (audioInput.readyForMoreMediaData) {
                                         CMSampleBufferRef sbuf = strongSelf ? [strongSelf.audioReaderOutput copyNextSampleBuffer] : NULL;
                                         if (!sbuf) {
                                           [audioInput markAsFinished];
                                           if (!left) {
                                             left = YES;
                                             dispatch_group_leave(group);
                                           }
                                           return;
                                         }
                                         BOOL ok = [audioInput appendSampleBuffer:sbuf];
                                         CFRelease(sbuf);
                                         if (!ok) {
                                           [audioInput markAsFinished];
                                           if (!left) {
                                             left = YES;
                                             dispatch_group_leave(group);
                                           }
                                           return;
                                         }
                                       }
                                     }];
}

- (void)appendFrame:(NSDictionary *)args result:(FlutterResult)result {
  // Called once per frame for the whole video — see the matching comment on
  // hdr_converter's videoReadFrame: for why this needs its own pool rather
  // than relying on whatever run loop turn eventually drains one.
  @autoreleasepool {
    if (!self.adaptor || self.writer.status != AVAssetWriterStatusWriting) {
      result([FlutterError errorWithCode:@"notReady" message:@"encoder not set up" details:nil]);
      return;
    }
    FlutterStandardTypedData *sdr = args[@"sdrRgba"];
    const uint8_t *sdrBytes = sdr.data.bytes;

    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(NULL, self.adaptor.pixelBufferPool, &pb);
    if (cv != kCVReturnSuccess || !pb) {
      result([FlutterError errorWithCode:@"poolBuffer"
                                message:[NSString stringWithFormat:@"CVPixelBufferPoolCreatePixelBuffer %d", cv]
                                details:nil]);
      return;
    }

    [self attachColorTagsTo:pb];
    CVPixelBufferLockBaseAddress(pb, 0);
    if (self.transfer == HdrTransferSdr709) {
      [self fillBgra:pb sdr:sdrBytes];
    } else {
      [self fillHalf:pb sdr:sdrBytes];
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    while (!self.videoInput.readyForMoreMediaData) {
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    CMTime pts = CMTimeMake(self.frameIdx, self.fps);
    BOOL ok = [self.adaptor appendPixelBuffer:pb withPresentationTime:pts];
    CVPixelBufferRelease(pb);
    if (!ok) {
      result([FlutterError errorWithCode:@"appendFailed"
                                message:self.writer.error.localizedDescription
                                details:nil]);
      return;
    }
    self.frameIdx += 1;
    result(nil);
  }
}

// Single-call video conversion: reads (AVAssetReader, mirroring
// hdr_converter's videoOpen/videoReadFrame), transforms, and writes
// (AVAssetWriter, mirroring setup:/appendFrame:) entirely natively, with no
// per-frame trip through Dart.
//
// The old design had Dart drive a per-frame loop — videoReadFrame() handed a
// full-resolution RGBA8 buffer to Dart, which immediately handed it back via
// appendFrame(). At 4K that's a ~33MB buffer crossing the Flutter method
// channel twice per frame on top of the native read buffer and the ~66MB
// half-float write buffer, and on a memory-constrained device (e.g. iPhone
// SE2, 3GB RAM) that was enough to get the app OS-killed under memory
// pressure (jetsam, reason "vm-pageshortage") converting a plain 4K clip.
// Transforming directly from the decoded source CVPixelBuffer into the
// destination CVPixelBuffer removes that extra buffer and both channel
// copies. Progress is reported by polling getConvertProgress rather than a
// native-to-Dart callback, to avoid needing a second, bidirectional channel
// handler for what's otherwise a one-way (Dart-calls-native) API.
//
// iOS-only for now (see convert_page.dart) — Android's existing per-frame
// path hasn't shown this problem (Bitmap.recycle() frees native memory
// immediately per frame, unlike relying on autorelease/GC timing).
- (void)convertVideo:(NSDictionary *)args result:(FlutterResult)result {
  NSString *inputPath = args[@"inputPath"];
  NSString *outputPath = args[@"outputPath"];
  int width = [args[@"width"] intValue];
  int height = [args[@"height"] intValue];
  int fps = [args[@"fps"] intValue];
  if (fps <= 0) fps = 30;
  int bitrate = [args[@"videoBitrate"] intValue];
  NSString *transferStr = args[@"transfer"];
  NSString *primariesStr = args[@"primaries"];
  float maxBoost = args[@"maxBoost"] ? [args[@"maxBoost"] floatValue] : 1.0f;
  if (maxBoost < 1.0f) maxBoost = 1.0f;
  float glowKnee = args[@"glowKnee"] ? [args[@"glowKnee"] floatValue] : 0.7f;
  float saturation = args[@"saturation"] ? [args[@"saturation"] floatValue] : 1.0f;
  if (saturation <= 0.0f) saturation = 1.0f;
  float maxCll = (args[@"maxContentLightLevel"] == nil || args[@"maxContentLightLevel"] == [NSNull null])
                     ? 0.0f
                     : [args[@"maxContentLightLevel"] floatValue];
  float maxFall = (args[@"maxFrameAverageLightLevel"] == nil || args[@"maxFrameAverageLightLevel"] == [NSNull null])
                      ? 0.0f
                      : [args[@"maxFrameAverageLightLevel"] floatValue];
  float sdrWhiteNits = (args[@"sdrWhiteNits"] == nil || args[@"sdrWhiteNits"] == [NSNull null])
                            ? kSdrWhiteNits
                            : [args[@"sdrWhiteNits"] floatValue];

  HdrTransferMode transfer = HdrTransferHlg;
  if ([transferStr isEqualToString:@"sdrRec709"]) transfer = HdrTransferSdr709;
  else if ([transferStr isEqualToString:@"pq"]) transfer = HdrTransferPq;
  HdrPrimariesMode primaries = HdrPrimaries2020;
  if ([primariesStr isEqualToString:@"rec709"]) primaries = HdrPrimaries709;
  else if ([primariesStr isEqualToString:@"displayP3"]) primaries = HdrPrimariesP3;
  if (transfer == HdrTransferSdr709) primaries = HdrPrimaries709;

  self.convertFrameIdx = 0;
  self.convertTotalFrames = 0;
  self.convertCancelRequested = NO;
  self.latestPreviewFrame = nil;
  self.latestPreviewWidth = 0;
  self.latestPreviewHeight = 0;
  self.latestPreviewGeneration = 0;

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    void (^finish)(id) = ^(id value) {
      dispatch_async(dispatch_get_main_queue(), ^{
        result(value);
      });
    };

    // ---- Reader (mirrors hdr_converter's videoOpen) ----
    NSURL *inURL = [NSURL fileURLWithPath:inputPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inURL options:nil];
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (tracks.count == 0) {
      finish([FlutterError errorWithCode:@"noVideoTrack" message:@"file has no video track" details:nil]);
      return;
    }
    AVAssetTrack *track = tracks.firstObject;
    CGAffineTransform transform = track.preferredTransform;

    // renderSize (width/height, the caller's possibly-downscaled target, e.g.
    // 4K capped to 1920 on the long edge — see _scaledVideoDimensions) can
    // differ from the track's own (rotation-applied) natural size. Without an
    // explicit scale on top of the rotation transform, AVFoundation draws the
    // source at its native pixel size positioned at the origin of the render
    // canvas — for a downscaled target that only fills the canvas's top-left
    // corner with a crop of the source, leaving the rest blank instead of the
    // whole frame scaled down.
    CGRect transformedRect = CGRectApplyAffineTransform(
        CGRectMake(0, 0, track.naturalSize.width, track.naturalSize.height), transform);
    CGSize transformedSize = CGSizeMake(fabs(transformedRect.size.width), fabs(transformedRect.size.height));
    CGAffineTransform renderTransform = transform;
    if (transformedSize.width > 0 && transformedSize.height > 0) {
      CGFloat sx = width / transformedSize.width;
      CGFloat sy = height / transformedSize.height;
      renderTransform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(sx, sy));
    }

    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = CGSizeMake(width, height);
    composition.frameDuration = CMTimeMake(1, (int32_t)fps);
    AVMutableVideoCompositionInstruction *instruction =
        [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    AVMutableVideoCompositionLayerInstruction *layerInstruction =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [layerInstruction setTransform:renderTransform atTime:kCMTimeZero];
    instruction.layerInstructions = @[ layerInstruction ];
    composition.instructions = @[ instruction ];

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (readerError) {
      finish([FlutterError errorWithCode:@"readerInit" message:readerError.localizedDescription details:nil]);
      return;
    }
    NSDictionary *readerOutputSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
    AVAssetReaderVideoCompositionOutput *readerOutput =
        [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[ track ]
                                                            videoSettings:readerOutputSettings];
    readerOutput.videoComposition = composition;
    if (![reader canAddOutput:readerOutput]) {
      finish([FlutterError errorWithCode:@"addOutput" message:@"cannot add video output" details:nil]);
      return;
    }
    [reader addOutput:readerOutput];

    // Audio passthrough: added as a second reader output (must happen before
    // startReading, below) so it's read from the same AVAssetReader as the
    // video composition output — copied verbatim (outputSettings:nil, no
    // decode/re-encode) into the writer on its own queue, concurrently with
    // the video frame loop below. nil (silent output) if the source has no
    // audio track.
    AVAssetTrack *audioTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    AVAssetReaderTrackOutput *audioReaderOutput = nil;
    if (audioTrack) {
      audioReaderOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:nil];
      if ([reader canAddOutput:audioReaderOutput]) {
        [reader addOutput:audioReaderOutput];
      } else {
        audioReaderOutput = nil;
      }
    }

    if (![reader startReading]) {
      finish([FlutterError errorWithCode:@"startReading"
                                  message:reader.error.localizedDescription
                                  details:nil]);
      return;
    }

    double durationSec = CMTimeGetSeconds(asset.duration);
    self.convertTotalFrames = MAX((int)round(durationSec * fps), 0);

    // ---- Writer (mirrors setup:) ----
    NSURL *outURL = [NSURL fileURLWithPath:outputPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
      [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
    }
    NSError *writerError = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outURL fileType:AVFileTypeMPEG4 error:&writerError];
    if (writerError) {
      [reader cancelReading];
      finish([FlutterError errorWithCode:@"writerInit" message:writerError.localizedDescription details:nil]);
      return;
    }

    NSString *primariesTag;
    NSString *matrixTag;
    switch (primaries) {
      case HdrPrimaries709:
        primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2;
        matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        break;
      case HdrPrimariesP3:
        primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_P3_D65;
        matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        break;
      case HdrPrimaries2020:
      default:
        primariesTag = (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020;
        matrixTag = (__bridge NSString *)kCVImageBufferYCbCrMatrix_ITU_R_2020;
        break;
    }
    NSString *transferTag;
    switch (transfer) {
      case HdrTransferSdr709:
        transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2;
        break;
      case HdrTransferPq:
        transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
        break;
      case HdrTransferHlg:
      default:
        transferTag = (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG;
        break;
    }

    NSMutableDictionary *compression = [@{
      AVVideoAverageBitRateKey : @(bitrate),
      AVVideoProfileLevelKey : (__bridge NSString *)kVTProfileLevel_HEVC_Main10_AutoLevel,
      @"HDRMetadataInsertionMode" : @"None",
    } mutableCopy];
    NSDictionary *colorProps = @{
      AVVideoColorPrimariesKey : primariesTag,
      AVVideoTransferFunctionKey : transferTag,
      AVVideoYCbCrMatrixKey : matrixTag,
    };
    NSDictionary *videoSettings = @{
      AVVideoCodecKey : AVVideoCodecTypeHEVC,
      AVVideoWidthKey : @(width),
      AVVideoHeightKey : @(height),
      AVVideoCompressionPropertiesKey : compression,
      AVVideoColorPropertiesKey : colorProps,
    };

    CMFormatDescriptionRef sourceFormatHint = NULL;
    if (transfer == HdrTransferPq) {
      float maxCllNits = maxCll > 0.0f ? maxCll : sdrWhiteNits;
      float maxFallNits = maxFall > 0.0f ? maxFall : sdrWhiteNits;
      NSDictionary *extensions = @{
        (__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries : primariesTag,
        (__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction : transferTag,
        (__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix : matrixTag,
        (__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume :
            HdrMasteringDisplayColorVolumeData(primaries),
        (__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo :
            HdrContentLightLevelData(maxCllNits, maxFallNits),
      };
      CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_HEVC, width, height,
                                      (__bridge CFDictionaryRef)extensions, &sourceFormatHint);
    }

    AVAssetWriterInput *videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                                    outputSettings:videoSettings
                                                                  sourceFormatHint:sourceFormatHint];
    if (sourceFormatHint) CFRelease(sourceFormatHint);
    videoInput.expectsMediaDataInRealTime = NO;

    OSType dstFormat = (transfer == HdrTransferSdr709) ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64RGBAHalf;
    NSDictionary *dstAttrs = @{
      (id)kCVPixelBufferPixelFormatTypeKey : @(dstFormat),
      (id)kCVPixelBufferWidthKey : @(width),
      (id)kCVPixelBufferHeightKey : @(height),
      (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                    sourcePixelBufferAttributes:dstAttrs];

    if (![writer canAddInput:videoInput]) {
      [reader cancelReading];
      finish([FlutterError errorWithCode:@"addInput" message:@"cannot add video input" details:nil]);
      return;
    }
    [writer addInput:videoInput];

    AVAssetWriterInput *audioInput = nil;
    if (audioReaderOutput) {
      audioInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:nil];
      audioInput.expectsMediaDataInRealTime = NO;
      if (![writer canAddInput:audioInput]) {
        audioInput = nil;
        audioReaderOutput = nil;
      } else {
        [writer addInput:audioInput];
      }
    }

    if (![writer startWriting]) {
      [reader cancelReading];
      finish([FlutterError errorWithCode:@"startWriting"
                                  message:writer.error.localizedDescription
                                  details:nil]);
      return;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    // Pump audio (if any) on its own queue, concurrently with the video frame
    // loop below — both outputs read from the same `reader`, but each output
    // is only ever touched from one thread, which AVAssetReader supports.
    // `stopAudio` mirrors self.convertCancelRequested/a genuine failure so the
    // audio pump stops promptly instead of running to completion after the
    // video side has already given up.
    __block BOOL stopAudio = NO;
    __block BOOL audioLeft = NO;
    dispatch_group_t audioGroup = nil;
    if (audioInput) {
      audioGroup = dispatch_group_create();
      dispatch_group_enter(audioGroup);
      dispatch_queue_t audioQueue = dispatch_queue_create("hdr_video_encoder.audio", DISPATCH_QUEUE_SERIAL);
      __weak typeof(self) weakSelf = self;
      AVAssetWriterInput *audioInputRef = audioInput;
      AVAssetReaderTrackOutput *audioReaderOutputRef = audioReaderOutput;
      dispatch_group_t audioGroupRef = audioGroup;
      [audioInputRef requestMediaDataWhenReadyOnQueue:audioQueue
                                            usingBlock:^{
                                              typeof(self) strongSelf = weakSelf;
                                              while (audioInputRef.readyForMoreMediaData) {
                                                if (stopAudio || strongSelf.convertCancelRequested) {
                                                  [audioInputRef markAsFinished];
                                                  if (!audioLeft) {
                                                    audioLeft = YES;
                                                    dispatch_group_leave(audioGroupRef);
                                                  }
                                                  return;
                                                }
                                                CMSampleBufferRef sbuf = [audioReaderOutputRef copyNextSampleBuffer];
                                                if (!sbuf) {
                                                  [audioInputRef markAsFinished];
                                                  if (!audioLeft) {
                                                    audioLeft = YES;
                                                    dispatch_group_leave(audioGroupRef);
                                                  }
                                                  return;
                                                }
                                                BOOL ok = [audioInputRef appendSampleBuffer:sbuf];
                                                CFRelease(sbuf);
                                                if (!ok) {
                                                  [audioInputRef markAsFinished];
                                                  if (!audioLeft) {
                                                    audioLeft = YES;
                                                    dispatch_group_leave(audioGroupRef);
                                                  }
                                                  return;
                                                }
                                              }
                                            }];
    }

    // ---- Frame loop ----
    int frameIdx = 0;
    BOOL failed = NO;
    NSString *failCode = nil;
    NSString *failMessage = nil;
    while (reader.status == AVAssetReaderStatusReading) {
      if (self.convertCancelRequested) break;
      @autoreleasepool {
        CMSampleBufferRef sbuf = [readerOutput copyNextSampleBuffer];
        if (!sbuf) break;
        CVPixelBufferRef srcPb = CMSampleBufferGetImageBuffer(sbuf);
        if (!srcPb) {
          CFRelease(sbuf);
          continue;
        }
        CVPixelBufferRef dstPb = NULL;
        CVReturn cv = CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &dstPb);
        if (cv != kCVReturnSuccess || !dstPb) {
          CFRelease(sbuf);
          failed = YES;
          failCode = @"poolBuffer";
          failMessage = [NSString stringWithFormat:@"CVPixelBufferPoolCreatePixelBuffer %d", cv];
          break;
        }

        CVPixelBufferLockBaseAddress(srcPb, kCVPixelBufferLock_ReadOnly);
        [self attachColorTagsTo:dstPb primaries:primaries transfer:transfer];
        CVPixelBufferLockBaseAddress(dstPb, 0);

        size_t srcW = CVPixelBufferGetWidth(srcPb);
        size_t srcH = CVPixelBufferGetHeight(srcPb);
        int readW = (int)MIN((size_t)width, srcW);
        int readH = (int)MIN((size_t)height, srcH);
        const uint8_t *srcBase = (const uint8_t *)CVPixelBufferGetBaseAddress(srcPb);
        size_t srcStride = CVPixelBufferGetBytesPerRow(srcPb);

        // Every few frames, capture a small live-preview thumbnail from the
        // (undecoded-HDR, but that doesn't matter for a progress thumbnail)
        // source — see getLatestPreviewFrame. Downscaled up front so
        // polling this doesn't reintroduce full-resolution buffers into
        // Dart, which is what convertVideo: exists to avoid.
        if (frameIdx % 5 == 0) {
          [self updatePreviewFromSrcBase:srcBase srcStride:srcStride srcW:readW srcH:readH];
        }

        if (transfer == HdrTransferSdr709) {
          [self fillBgraDirect:dstPb
                          width:width
                         height:height
                        srcBase:srcBase
                      srcStride:srcStride
                          readW:readW
                          readH:readH];
        } else {
          [self fillHalfDirect:dstPb
                          width:width
                         height:height
                       maxBoost:maxBoost
                           knee:glowKnee
                     saturation:saturation
                    cllLimitNits:(maxCll > 0.0f ? maxCll : 10000.0f)
                   sdrWhiteNits:sdrWhiteNits
                       transfer:transfer
                      primaries:primaries
                        srcBase:srcBase
                      srcStride:srcStride
                          readW:readW
                          readH:readH];
        }

        CVPixelBufferUnlockBaseAddress(dstPb, 0);
        CVPixelBufferUnlockBaseAddress(srcPb, kCVPixelBufferLock_ReadOnly);
        CFRelease(sbuf);

        while (!videoInput.readyForMoreMediaData) {
          [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        CMTime pts = CMTimeMake(frameIdx, fps);
        BOOL ok = [adaptor appendPixelBuffer:dstPb withPresentationTime:pts];
        CVPixelBufferRelease(dstPb);
        if (!ok) {
          failed = YES;
          failCode = @"appendFailed";
          failMessage = writer.error.localizedDescription;
          break;
        }
        frameIdx++;
        self.convertFrameIdx = frameIdx;
      }
    }

    // Let the audio pump run to completion (or stop on its own via
    // convertCancelRequested) before tearing down the shared reader — cancelling
    // it early would truncate whatever audio hadn't been copied yet.
    if (failed) stopAudio = YES;
    if (audioGroup) {
      dispatch_group_wait(audioGroup, DISPATCH_TIME_FOREVER);
    }
    [reader cancelReading];

    if (failed) {
      [videoInput markAsFinished];
      [writer cancelWriting];
      [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
      finish([FlutterError errorWithCode:failCode message:failMessage details:nil]);
      return;
    }

    [videoInput markAsFinished];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [writer finishWritingWithCompletionHandler:^{
      dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (self.convertCancelRequested) {
      [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
      finish([FlutterError errorWithCode:@"cancelled" message:@"conversion cancelled" details:nil]);
      return;
    }
    if (writer.status == AVAssetWriterStatusFailed) {
      [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
      finish([FlutterError errorWithCode:@"finishFailed" message:writer.error.localizedDescription details:nil]);
      return;
    }
    [self stripDolbyVisionBoxFromFile:outputPath];
    [self relocateMoovBeforeMdatInFile:outputPath];
    finish(nil);
  });
}

- (void)attachColorTagsTo:(CVPixelBufferRef)pb
                 primaries:(HdrPrimariesMode)primaries
                  transfer:(HdrTransferMode)transfer {
  CFStringRef primariesTag;
  CFStringRef matrixTag;
  switch (primaries) {
    case HdrPrimaries709:
      primariesTag = kCVImageBufferColorPrimaries_ITU_R_709_2;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimariesP3:
      primariesTag = kCVImageBufferColorPrimaries_P3_D65;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimaries2020:
    default:
      primariesTag = kCVImageBufferColorPrimaries_ITU_R_2020;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_2020;
      break;
  }
  CFStringRef transferTag;
  switch (transfer) {
    case HdrTransferSdr709: transferTag = kCVImageBufferTransferFunction_ITU_R_709_2; break;
    case HdrTransferPq: transferTag = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ; break;
    case HdrTransferHlg:
    default: transferTag = kCVImageBufferTransferFunction_ITU_R_2100_HLG; break;
  }
  CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primariesTag, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transferTag, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrixTag, kCVAttachmentMode_ShouldPropagate);
}

// Same as fillBgra:sdr: but reads BGRA directly from the decoded source
// CVPixelBuffer (respecting its own stride) instead of a tightly-packed RGBA
// buffer — no intermediate copy/byte-swizzle needed.
// Nearest-neighbour downscale of a BGRA source into a small RGBA thumbnail
// (long edge capped at 480px) for the live preview — see
// latestPreviewFrame. Quality doesn't matter here, only staying cheap and
// small: this runs once every few frames on the hot conversion loop.
- (void)updatePreviewFromSrcBase:(const uint8_t *)srcBase srcStride:(size_t)srcStride srcW:(int)srcW srcH:(int)srcH {
  if (srcW <= 0 || srcH <= 0) return;
  const int maxDim = 480;
  int longEdge = MAX(srcW, srcH);
  float scale = longEdge > maxDim ? (float)maxDim / (float)longEdge : 1.0f;
  int outW = MAX(1, (int)(srcW * scale));
  int outH = MAX(1, (int)(srcH * scale));

  NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)outW * outH * 4];
  uint8_t *dst = (uint8_t *)out.mutableBytes;
  for (int y = 0; y < outH; y++) {
    int sy = (int)(y / scale);
    if (sy >= srcH) sy = srcH - 1;
    const uint8_t *srow = srcBase + (size_t)sy * srcStride;
    uint8_t *drow = dst + (size_t)y * outW * 4;
    for (int x = 0; x < outW; x++) {
      int sx = (int)(x / scale);
      if (sx >= srcW) sx = srcW - 1;
      const uint8_t *sp = srow + (size_t)sx * 4;  // BGRA
      uint8_t *dp = drow + (size_t)x * 4;
      dp[0] = sp[2];  // R
      dp[1] = sp[1];  // G
      dp[2] = sp[0];  // B
      dp[3] = sp[3];  // A
    }
  }

  self.latestPreviewFrame = out;
  self.latestPreviewWidth = outW;
  self.latestPreviewHeight = outH;
  self.latestPreviewGeneration += 1;
}

- (void)fillBgraDirect:(CVPixelBufferRef)pb
                  width:(int)w
                 height:(int)h
                srcBase:(const uint8_t *)srcBase
              srcStride:(size_t)srcStride
                  readW:(int)readW
                  readH:(int)readH {
  uint8_t *base = CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  for (int y = 0; y < readH; y++) {
    const uint8_t *src = srcBase + (size_t)y * srcStride;  // BGRA
    uint8_t *dst = base + (size_t)y * stride;
    for (int x = 0; x < readW; x++) {
      dst[x * 4 + 0] = src[x * 4 + 0];
      dst[x * 4 + 1] = src[x * 4 + 1];
      dst[x * 4 + 2] = src[x * 4 + 2];
      dst[x * 4 + 3] = src[x * 4 + 3];
    }
    if (readW < w) {
      memset(dst + readW * 4, 0, (size_t)(w - readW) * 4);
    }
  }
  if (readH < h) {
    memset(base + (size_t)readH * stride, 0, (size_t)(h - readH) * stride);
  }
}

// Same colour maths as fillHalf:sdr:, reading BGRA directly from the decoded
// source CVPixelBuffer instead of a tightly-packed RGBA buffer.
- (void)fillHalfDirect:(CVPixelBufferRef)pb
                  width:(int)w
                 height:(int)h
               maxBoost:(float)maxBoost
                   knee:(float)knee
             saturation:(float)sat
           cllLimitNits:(float)cllLimitNits
           sdrWhiteNits:(float)sdrWhiteNits
               transfer:(HdrTransferMode)tf
              primaries:(HdrPrimariesMode)pm
                srcBase:(const uint8_t *)srcBase
              srcStride:(size_t)srcStride
                  readW:(int)readW
                  readH:(int)readH {
  __fp16 *base = (__fp16 *)CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);  // bytes

  for (int y = 0; y < readH; y++) {
    const uint8_t *srow = srcBase + (size_t)y * srcStride;  // BGRA
    __fp16 *drow = (__fp16 *)((uint8_t *)base + (size_t)y * stride);
    for (int x = 0; x < readW; x++) {
      float sb = srow[x * 4 + 0] / 255.0f;
      float sg = srow[x * 4 + 1] / 255.0f;
      float sr = srow[x * 4 + 2] / 255.0f;
      float k = glowFactorf(fminf(sr, fminf(sg, sb)), knee, maxBoost);
      float r = srgbToLinear(sr) * k;
      float g = srgbToLinear(sg) * k;
      float b = srgbToLinear(sb) * k;

      if (sat != 1.0f) {
        float yy = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        r = yy + sat * (r - yy);
        g = yy + sat * (g - yy);
        b = yy + sat * (b - yy);
      }

      if (pm == HdrPrimaries2020) lin709ToLin2020(&r, &g, &b);
      else if (pm == HdrPrimariesP3) lin709ToLinP3(&r, &g, &b);

      float er, eg, eb;
      if (tf == HdrTransferPq) {
        float pr = fminf(r * sdrWhiteNits, cllLimitNits) / 10000.0f;
        float pg = fminf(g * sdrWhiteNits, cllLimitNits) / 10000.0f;
        float pb2 = fminf(b * sdrWhiteNits, cllLimitNits) / 10000.0f;
        er = pqOetf(pr); eg = pqOetf(pg); eb = pqOetf(pb2);
      } else {  // HLG
        float yl = 0.2627f * r + 0.6780f * g + 0.0593f * b;  // BT.2020 luma
        float comp = powf(fmaxf(yl, 1.0e-4f), -1.0f / 3.0f);
        if (comp > 2.5f) comp = 2.5f;
        er = hlgOetf(r * comp * kHlgSdrWhiteScene);
        eg = hlgOetf(g * comp * kHlgSdrWhiteScene);
        eb = hlgOetf(b * comp * kHlgSdrWhiteScene);
      }

      drow[x * 4 + 0] = (__fp16)er;
      drow[x * 4 + 1] = (__fp16)eg;
      drow[x * 4 + 2] = (__fp16)eb;
      drow[x * 4 + 3] = (__fp16)1.0f;
    }
    // Zero any unread tail column so a smaller-than-expected source buffer
    // (see hdr_converter's videoReadFrame for why that can happen) leaves
    // black rather than uninitialized memory past readW.
    if (readW < w) {
      memset(drow + readW * 4, 0, (size_t)(w - readW) * 4 * sizeof(__fp16));
    }
  }
  if (readH < h) {
    memset((uint8_t *)base + (size_t)readH * stride, 0, (size_t)(h - readH) * stride);
  }
}

- (void)attachColorTagsTo:(CVPixelBufferRef)pb {
  CFStringRef primariesTag;
  CFStringRef matrixTag;
  switch (self.primaries) {
    case HdrPrimaries709:
      primariesTag = kCVImageBufferColorPrimaries_ITU_R_709_2;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimariesP3:
      primariesTag = kCVImageBufferColorPrimaries_P3_D65;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
      break;
    case HdrPrimaries2020:
    default:
      primariesTag = kCVImageBufferColorPrimaries_ITU_R_2020;
      matrixTag = kCVImageBufferYCbCrMatrix_ITU_R_2020;
      break;
  }
  CFStringRef transferTag;
  switch (self.transfer) {
    case HdrTransferSdr709: transferTag = kCVImageBufferTransferFunction_ITU_R_709_2; break;
    case HdrTransferPq: transferTag = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ; break;
    case HdrTransferHlg:
    default: transferTag = kCVImageBufferTransferFunction_ITU_R_2100_HLG; break;
  }
  CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primariesTag, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transferTag, kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrixTag, kCVAttachmentMode_ShouldPropagate);
}

// SDR checkpoint: straight RGBA8 -> BGRA8, no colour math.
- (void)fillBgra:(CVPixelBufferRef)pb sdr:(const uint8_t *)sdr {
  uint8_t *base = CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  int w = self.width, h = self.height;
  for (int y = 0; y < h; y++) {
    const uint8_t *src = sdr + (size_t)y * w * 4;
    uint8_t *dst = base + (size_t)y * stride;
    for (int x = 0; x < w; x++) {
      dst[x * 4 + 0] = src[x * 4 + 2];
      dst[x * 4 + 1] = src[x * 4 + 1];
      dst[x * 4 + 2] = src[x * 4 + 0];
      dst[x * 4 + 3] = src[x * 4 + 3];
    }
  }
}

// HDR: RGBA8 sRGB -> RGBA-half in the target transfer function and primaries,
// with a uniform whiteness-driven glow (a pure function of the sRGB value).
// Alpha forced opaque (HDR video has no alpha).
- (void)fillHalf:(CVPixelBufferRef)pb sdr:(const uint8_t *)sdr {
  __fp16 *base = (__fp16 *)CVPixelBufferGetBaseAddress(pb);
  size_t stride = CVPixelBufferGetBytesPerRow(pb);  // bytes
  int w = self.width, h = self.height;
  float maxBoost = self.maxBoost;
  float knee = self.glowKnee;
  float sat = self.saturation;
  float cllLimitNits = self.maxCll > 0.0f ? self.maxCll : 10000.0f;
  float sdrWhiteNits = self.sdrWhiteNits;
  HdrTransferMode tf = self.transfer;
  HdrPrimariesMode pm = self.primaries;

  for (int y = 0; y < h; y++) {
    const uint8_t *srow = sdr + (size_t)y * w * 4;
    __fp16 *drow = (__fp16 *)((uint8_t *)base + (size_t)y * stride);
    for (int x = 0; x < w; x++) {
      float sr = srow[x * 4 + 0] / 255.0f;
      float sg = srow[x * 4 + 1] / 255.0f;
      float sb = srow[x * 4 + 2] / 255.0f;
      float k = glowFactorf(fminf(sr, fminf(sg, sb)), knee, maxBoost);
      float r = srgbToLinear(sr) * k;
      float g = srgbToLinear(sg) * k;
      float b = srgbToLinear(sb) * k;

      // Luma-preserving saturation nudge in linear light (see hdr_color_math).
      if (sat != 1.0f) {
        float yy = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        r = yy + sat * (r - yy);
        g = yy + sat * (g - yy);
        b = yy + sat * (b - yy);
      }

      if (pm == HdrPrimaries2020) lin709ToLin2020(&r, &g, &b);
      else if (pm == HdrPrimariesP3) lin709ToLinP3(&r, &g, &b);

      float er, eg, eb;
      if (tf == HdrTransferPq) {
        float sr = fminf(r * sdrWhiteNits, cllLimitNits) / 10000.0f;
        float sg = fminf(g * sdrWhiteNits, cllLimitNits) / 10000.0f;
        float sb = fminf(b * sdrWhiteNits, cllLimitNits) / 10000.0f;
        er = pqOetf(sr); eg = pqOetf(sg); eb = pqOetf(sb);
      } else {  // HLG
        // Inverse OOTF: a phone renders HLG through an effective system gamma
        // that crushes mid-tones/shadows below their SDR appearance. Undo it
        // with one luma-driven factor (white -> 1.0) so hue is untouched.
        // exponent -(g-1)/g, g = 1.5 (-1/3) — tuned up from the 1.2 reference.
        float yl = 0.2627f * r + 0.6780f * g + 0.0593f * b;  // BT.2020 luma
        float comp = powf(fmaxf(yl, 1.0e-4f), -1.0f / 3.0f);
        if (comp > 2.5f) comp = 2.5f;  // don't lift near-black arbitrarily far
        er = hlgOetf(r * comp * kHlgSdrWhiteScene);
        eg = hlgOetf(g * comp * kHlgSdrWhiteScene);
        eb = hlgOetf(b * comp * kHlgSdrWhiteScene);
      }

      drow[x * 4 + 0] = (__fp16)er;
      drow[x * 4 + 1] = (__fp16)eg;
      drow[x * 4 + 2] = (__fp16)eb;
      drow[x * 4 + 3] = (__fp16)1.0f;
    }
  }
}

- (void)finish:(FlutterResult)result {
  if (!self.writer) {
    result([FlutterError errorWithCode:@"notReady" message:@"nothing to finish" details:nil]);
    return;
  }
  [self.videoInput markAsFinished];

  if (self.audioGroup) {
    dispatch_group_wait(self.audioGroup, DISPATCH_TIME_FOREVER);
  }
  [self.audioReader cancelReading];
  self.audioReader = nil;
  self.audioReaderOutput = nil;
  self.audioInput = nil;
  self.audioGroup = nil;

  dispatch_group_t group = dispatch_group_create();
  dispatch_group_enter(group);
  __weak typeof(self) weakSelf = self;
  [self.writer finishWritingWithCompletionHandler:^{
    dispatch_group_leave(group);
  }];
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  AVAssetWriterStatus status = self.writer.status;
  NSError *err = self.writer.error;
  self.writer = nil;
  self.videoInput = nil;
  self.adaptor = nil;
  if (status == AVAssetWriterStatusFailed) {
    result([FlutterError errorWithCode:@"finishFailed" message:err.localizedDescription details:nil]);
    return;
  }
  (void)weakSelf;
  [self stripDolbyVisionBoxFromFile:self.filepath];
  [self relocateMoovBeforeMdatInFile:self.filepath];
  result(nil);
}

@end
