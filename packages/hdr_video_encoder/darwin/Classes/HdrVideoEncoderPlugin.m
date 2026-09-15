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

@implementation HdrVideoEncoderPlugin

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

- (void)setup:(NSDictionary *)args result:(FlutterResult)result {
  self.width = [args[@"width"] intValue];
  self.height = [args[@"height"] intValue];
  self.fps = [args[@"fps"] intValue];
  self.frameIdx = 0;
  int bitrate = [args[@"videoBitrate"] intValue];
  NSString *filepath = args[@"filepath"];
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
  result(nil);
}

- (void)appendFrame:(NSDictionary *)args result:(FlutterResult)result {
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
  result(nil);
}

@end
