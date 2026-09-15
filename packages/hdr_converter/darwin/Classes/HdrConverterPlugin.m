#import "HdrConverterPlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <math.h>

// ---------------------------------------------------------------------------
// Colour-science helpers — copy of the per-pixel transform in
// hdr_video_encoder's darwin/Classes/HdrVideoEncoderPlugin.m (and
// lib/src/hdr_color_math.dart). KEEP IN SYNC — same formulas/constants.
// ---------------------------------------------------------------------------

static inline float srgbToLinear(float c) {
  if (c <= 0.04045f) return c / 12.92f;
  return powf((c + 0.055f) / 1.055f, 2.4f);
}

static inline void lin709ToLin2020(float *r, float *g, float *b) {
  float R = *r, G = *g, B = *b;
  *r = 0.62740f * R + 0.32930f * G + 0.04330f * B;
  *g = 0.06910f * R + 0.91950f * G + 0.01140f * B;
  *b = 0.01640f * R + 0.08800f * G + 0.89560f * B;
}

static inline void lin709ToLinP3(float *r, float *g, float *b) {
  float R = *r, G = *g, B = *b;
  *r = 0.822462f * R + 0.177538f * G + 0.0f * B;
  *g = 0.033194f * R + 0.966806f * G + 0.0f * B;
  *b = 0.017083f * R + 0.072397f * G + 0.910520f * B;
}

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

static inline float hlgOetf(float E) {
  if (E < 0.0f) E = 0.0f;
  if (E > 1.0f) E = 1.0f;
  const float a = 0.17883277f;
  const float b = 0.28466892f;
  const float c = 0.55991073f;
  if (E <= 1.0f / 12.0f) return sqrtf(3.0f * E);
  return a * logf(12.0f * E - b) + c;
}

static inline float smoothstepf(float e0, float e1, float x) {
  if (e1 <= e0) return x < e0 ? 0.0f : 1.0f;
  float t = (x - e0) / (e1 - e0);
  if (t < 0.0f) t = 0.0f;
  if (t > 1.0f) t = 1.0f;
  return t * t * (3.0f - 2.0f * t);
}

static inline float glowFactorf(float whiteness, float knee, float maxBoost) {
  return 1.0f + smoothstepf(knee, 1.0f, whiteness) * (maxBoost - 1.0f);
}

static const float kSdrWhiteNits = 203.0f;
static const float kHlgSdrWhiteScene = 0.5f;

typedef NS_ENUM(NSInteger, HdrTransferMode) { HdrTransferHlg = 1, HdrTransferPq = 2 };
typedef NS_ENUM(NSInteger, HdrPrimariesMode) { HdrPrimaries2020 = 0, HdrPrimariesP3 = 1 };

// ---------------------------------------------------------------------------

@interface HdrConverterPlugin ()
@property(nonatomic) FlutterMethodChannel *channel;

// Video decode session state (one at a time).
@property(nonatomic) AVAssetReader *videoReader;
@property(nonatomic) AVAssetReaderOutput *videoOutput;
@property(nonatomic) int videoWidth;
@property(nonatomic) int videoHeight;
@end

@implementation HdrConverterPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
#if TARGET_OS_OSX
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"hdr_converter/methods"
                                   binaryMessenger:registrar.messenger];
#else
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"hdr_converter/methods"
                                   binaryMessenger:[registrar messenger]];
#endif
  HdrConverterPlugin *instance = [[HdrConverterPlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  @try {
    if ([@"videoOpen" isEqualToString:call.method]) {
      [self videoOpen:call.arguments result:result];
    } else if ([@"videoReadFrame" isEqualToString:call.method]) {
      [self videoReadFrame:result];
    } else if ([@"videoClose" isEqualToString:call.method]) {
      [self videoClose:result];
    } else if ([@"probeVideoSource" isEqualToString:call.method]) {
      [self probeVideoSource:call.arguments result:result];
    } else if ([@"probeImage" isEqualToString:call.method]) {
      result(@{@"supported" : @YES, @"reason" : [NSNull null]});
    } else if ([@"probeImageSource" isEqualToString:call.method]) {
      [self probeImageSource:call.arguments result:result];
    } else if ([@"convertImage" isEqualToString:call.method]) {
      [self convertImage:call.arguments result:result];
    } else {
      result(FlutterMethodNotImplemented);
    }
  } @catch (NSException *e) {
    result([FlutterError errorWithCode:@"hdrConverterException"
                                message:e.reason
                                details:[[e callStackSymbols] componentsJoinedByString:@"\n"]]);
  }
}

#pragma mark - Video decode

- (void)videoOpen:(NSDictionary *)args result:(FlutterResult)result {
  [self teardownVideoReader];

  NSString *path = args[@"path"];
  NSURL *url = [NSURL fileURLWithPath:path];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  if (tracks.count == 0) {
    result([FlutterError errorWithCode:@"noVideoTrack" message:@"file has no video track" details:nil]);
    return;
  }
  AVAssetTrack *track = tracks.firstObject;

  CGSize naturalSize = track.naturalSize;
  CGAffineTransform transform = track.preferredTransform;
  CGSize renderSizeF = CGSizeApplyAffineTransform(naturalSize, transform);
  int width = (int)round(fabs(renderSizeF.width));
  int height = (int)round(fabs(renderSizeF.height));
  // HEVC Main10 needs even dimensions (hdr_video_encoder asserts this).
  if (width % 2 != 0) width -= 1;
  if (height % 2 != 0) height -= 1;
  if (width < 2 || height < 2) {
    result([FlutterError errorWithCode:@"badDimensions" message:@"could not determine video size" details:nil]);
    return;
  }

  float fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30.0f;

  AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
  composition.renderSize = CGSizeMake(width, height);
  composition.frameDuration = CMTimeMake(1, (int32_t)round(fps));

  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
  [layerInstruction setTransform:transform atTime:kCMTimeZero];
  instruction.layerInstructions = @[ layerInstruction ];
  composition.instructions = @[ instruction ];

  NSError *error = nil;
  AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
  if (error) {
    result([FlutterError errorWithCode:@"readerInit" message:error.localizedDescription details:nil]);
    return;
  }

  NSDictionary *outputSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
  };
  AVAssetReaderVideoCompositionOutput *output =
      [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[ track ]
                                                          videoSettings:outputSettings];
  output.videoComposition = composition;
  if (![reader canAddOutput:output]) {
    result([FlutterError errorWithCode:@"addOutput" message:@"cannot add video output" details:nil]);
    return;
  }
  [reader addOutput:output];
  if (![reader startReading]) {
    result([FlutterError errorWithCode:@"startReading"
                                message:reader.error.localizedDescription
                                details:nil]);
    return;
  }

  self.videoReader = reader;
  self.videoOutput = output;
  self.videoWidth = width;
  self.videoHeight = height;

  double durationSec = CMTimeGetSeconds(asset.duration);
  int frameCount = (int)round(durationSec * fps);
  result(@{
    @"width" : @(width),
    @"height" : @(height),
    @"fps" : @((int)round(fps)),
    @"frameCount" : @(MAX(frameCount, 0)),
  });
}

- (void)videoReadFrame:(FlutterResult)result {
  if (!self.videoOutput || self.videoReader.status != AVAssetReaderStatusReading) {
    result(nil);
    return;
  }
  CMSampleBufferRef sbuf = [self.videoOutput copyNextSampleBuffer];
  if (!sbuf) {
    result(nil);
    return;
  }
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
  if (!pb) {
    CFRelease(sbuf);
    result(nil);
    return;
  }

  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  int w = self.videoWidth, h = self.videoHeight;
  size_t stride = CVPixelBufferGetBytesPerRow(pb);
  const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
  NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
  uint8_t *dst = (uint8_t *)rgba.mutableBytes;
  for (int y = 0; y < h; y++) {
    const uint8_t *srow = base + (size_t)y * stride;  // BGRA
    uint8_t *drow = dst + (size_t)y * w * 4;
    for (int x = 0; x < w; x++) {
      drow[x * 4 + 0] = srow[x * 4 + 2];  // R
      drow[x * 4 + 1] = srow[x * 4 + 1];  // G
      drow[x * 4 + 2] = srow[x * 4 + 0];  // B
      drow[x * 4 + 3] = srow[x * 4 + 3];  // A
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CFRelease(sbuf);

  result([FlutterStandardTypedData typedDataWithBytes:rgba]);
}

- (void)videoClose:(FlutterResult)result {
  [self teardownVideoReader];
  result(nil);
}

- (void)teardownVideoReader {
  if (self.videoReader && self.videoReader.status == AVAssetReaderStatusReading) {
    [self.videoReader cancelReading];
  }
  self.videoReader = nil;
  self.videoOutput = nil;
  self.videoWidth = 0;
  self.videoHeight = 0;
}

// Checks the video track's own transfer-function tag — the exact tag our
// own encoder writes (kCVImageBufferTransferFunction_ITU_R_2100_HLG /
// _SMPTE_ST_2084_PQ), so this also reliably catches our own HDR output.
- (void)probeVideoSource:(NSDictionary *)args result:(FlutterResult)result {
  NSString *path = args[@"path"];
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
  if (tracks.count == 0) {
    result(@{@"isHdr" : @NO, @"reason" : [NSNull null]});
    return;
  }
  AVAssetTrack *track = tracks.firstObject;
  BOOL isHdr = NO;
  for (id descObj in track.formatDescriptions) {
    CMFormatDescriptionRef desc = (__bridge CMFormatDescriptionRef)descObj;
    CFStringRef transfer =
        (CFStringRef)CMFormatDescriptionGetExtension(desc, kCMFormatDescriptionExtension_TransferFunction);
    if (transfer && (CFStringCompare(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG, 0) == kCFCompareEqualTo ||
                     CFStringCompare(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, 0) == kCFCompareEqualTo)) {
      isHdr = YES;
      break;
    }
  }
  result(@{
    @"isHdr" : @(isHdr),
    @"reason" : isHdr ? @"Already an HDR (HLG/PQ) video." : [NSNull null],
  });
}

#pragma mark - Image conversion

// Two independent HDR signals: (1) Apple's camera "HDR photo" gain-map
// auxiliary data (iPhone HEIC/JPEG shot in the default camera app), and
// (2) an explicit HLG/PQ colour-space tag — the exact tags our own
// convertImage writes, so this also catches our own output.
- (void)probeImageSource:(NSDictionary *)args result:(FlutterResult)result {
  NSString *path = args[@"path"];
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef srcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!srcRef) {
    result(@{@"isHdr" : @NO, @"reason" : [NSNull null]});
    return;
  }

  BOOL isHdr = NO;
  CFDictionaryRef auxData =
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(srcRef, 0, kCGImageAuxiliaryDataTypeHDRGainMap);
  if (auxData) {
    isHdr = YES;
    CFRelease(auxData);
  }

  if (!isHdr) {
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(srcRef, 0, NULL);
    if (cgImage) {
      CGColorSpaceRef cs = CGImageGetColorSpace(cgImage);
      CFStringRef name = cs ? CGColorSpaceGetName(cs) : NULL;
      if (name && (CFStringCompare(name, kCGColorSpaceITUR_2100_HLG, 0) == kCFCompareEqualTo ||
                   CFStringCompare(name, kCGColorSpaceITUR_2100_PQ, 0) == kCFCompareEqualTo ||
                   CFStringCompare(name, kCGColorSpaceDisplayP3_HLG, 0) == kCFCompareEqualTo)) {
        isHdr = YES;
      }
      CGImageRelease(cgImage);
    }
  }
  CFRelease(srcRef);

  result(@{
    @"isHdr" : @(isHdr),
    @"reason" : isHdr ? @"Already an HDR image." : [NSNull null],
  });
}

- (void)convertImage:(NSDictionary *)args result:(FlutterResult)result {
  NSString *inputPath = args[@"inputPath"];
  NSString *outputPath = args[@"outputPath"];
  NSString *transferStr = args[@"transfer"];
  NSString *primariesStr = args[@"primaries"];
  float maxBoost = [args[@"maxBoost"] floatValue];
  if (maxBoost < 1.0f) maxBoost = 1.0f;
  float glowKnee = args[@"glowKnee"] ? [args[@"glowKnee"] floatValue] : 0.7f;
  float saturation = args[@"saturation"] ? [args[@"saturation"] floatValue] : 1.0f;
  if (saturation <= 0.0f) saturation = 1.0f;
  float sdrWhiteNits = args[@"sdrWhiteNits"] ? [args[@"sdrWhiteNits"] floatValue] : kSdrWhiteNits;

  HdrTransferMode transfer = [@"pq" isEqualToString:transferStr] ? HdrTransferPq : HdrTransferHlg;
  // Ultra-HDR-style combos are Apple-defined named colour spaces; PQ is only
  // shipped paired with Rec.2020 primaries, so pin PQ to 2020 regardless of
  // the requested primaries (keeps the CGColorSpace tag and the per-pixel
  // primaries matrix in agreement).
  HdrPrimariesMode primaries =
      (transfer == HdrTransferHlg && [@"displayP3" isEqualToString:primariesStr])
          ? HdrPrimariesP3
          : HdrPrimaries2020;

  NSURL *inURL = [NSURL fileURLWithPath:inputPath];
  CGImageSourceRef srcRef = CGImageSourceCreateWithURL((__bridge CFURLRef)inURL, NULL);
  if (!srcRef) {
    result([FlutterError errorWithCode:@"decodeFailed" message:@"could not open input image" details:nil]);
    return;
  }
  CGImageRef cgImage = CGImageSourceCreateImageAtIndex(srcRef, 0, NULL);
  CFRelease(srcRef);
  if (!cgImage) {
    result([FlutterError errorWithCode:@"decodeFailed" message:@"could not decode input image" details:nil]);
    return;
  }

  size_t width = CGImageGetWidth(cgImage);
  size_t height = CGImageGetHeight(cgImage);

  // Normalise to 8-bit sRGB RGBA regardless of the source's own colour space.
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  size_t srcStride = width * 4;
  uint8_t *srcBuf = (uint8_t *)calloc(srcStride * height, 1);
  CGContextRef srcCtx = CGBitmapContextCreate(
      srcBuf, width, height, 8, srcStride, srgb,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGContextDrawImage(srcCtx, CGRectMake(0, 0, width, height), cgImage);
  CGContextRelease(srcCtx);
  CGColorSpaceRelease(srgb);
  CGImageRelease(cgImage);

  // Per-pixel transform -> half-float RGBA in the target transfer/primaries.
  // Same maths as hdr_video_encoder's fillHalf; alpha forced opaque (HDR
  // stills authored this way have no meaningful alpha channel here).
  size_t dstStride = width * 4 * sizeof(__fp16);
  __fp16 *dstBuf = (__fp16 *)malloc(dstStride * height);
  for (size_t y = 0; y < height; y++) {
    const uint8_t *srow = srcBuf + y * srcStride;
    __fp16 *drow = dstBuf + y * width * 4;
    for (size_t x = 0; x < width; x++) {
      float sr = srow[x * 4 + 0] / 255.0f;
      float sg = srow[x * 4 + 1] / 255.0f;
      float sb = srow[x * 4 + 2] / 255.0f;
      float k = glowFactorf(fminf(sr, fminf(sg, sb)), glowKnee, maxBoost);
      float r = srgbToLinear(sr) * k;
      float g = srgbToLinear(sg) * k;
      float b = srgbToLinear(sb) * k;

      if (saturation != 1.0f) {
        float yy = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        r = yy + saturation * (r - yy);
        g = yy + saturation * (g - yy);
        b = yy + saturation * (b - yy);
      }

      if (primaries == HdrPrimaries2020) {
        lin709ToLin2020(&r, &g, &b);
      } else {
        lin709ToLinP3(&r, &g, &b);
      }

      float er, eg, eb;
      if (transfer == HdrTransferPq) {
        er = pqOetf(fminf(r * sdrWhiteNits, 10000.0f) / 10000.0f);
        eg = pqOetf(fminf(g * sdrWhiteNits, 10000.0f) / 10000.0f);
        eb = pqOetf(fminf(b * sdrWhiteNits, 10000.0f) / 10000.0f);
      } else {
        float yl = 0.2627f * r + 0.6780f * g + 0.0593f * b;
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
  }
  free(srcBuf);

  CFStringRef colorSpaceName;
  if (transfer == HdrTransferPq) {
    colorSpaceName = kCGColorSpaceITUR_2100_PQ;
  } else if (primaries == HdrPrimariesP3) {
    colorSpaceName = kCGColorSpaceDisplayP3_HLG;
  } else {
    colorSpaceName = kCGColorSpaceITUR_2100_HLG;
  }
  CGColorSpaceRef hdrCS = CGColorSpaceCreateWithName(colorSpaceName);
  if (!hdrCS) {
    free(dstBuf);
    result([FlutterError errorWithCode:@"colorSpace" message:@"HDR colour space unavailable on this OS" details:nil]);
    return;
  }

  CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, dstBuf, dstStride * height, ReleaseHalfFloatBuffer);
  CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGBitmapFloatComponents | kCGBitmapByteOrder16Host |
                            (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
  CGImageRef hdrImage = CGImageCreate(width, height, 16, 64, dstStride, hdrCS, bitmapInfo, provider, NULL, false,
                                       kCGRenderingIntentDefault);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(hdrCS);
  if (!hdrImage) {
    result([FlutterError errorWithCode:@"encodeFailed" message:@"could not build HDR image" details:nil]);
    return;
  }

  NSURL *outURL = [NSURL fileURLWithPath:outputPath];
  [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)outURL, (CFStringRef)@"public.heic", 1, NULL);
  if (!dest) {
    CGImageRelease(hdrImage);
    result([FlutterError errorWithCode:@"noHeicDestination" message:@"HEIC encoding is not available on this device" details:nil]);
    return;
  }
  NSDictionary *destProps = @{(id)kCGImageDestinationLossyCompressionQuality : @(0.9)};
  CGImageDestinationAddImage(dest, hdrImage, (__bridge CFDictionaryRef)destProps);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(hdrImage);

  if (!ok) {
    result([FlutterError errorWithCode:@"finalizeFailed" message:@"failed to write HEIC output" details:nil]);
    return;
  }
  result(nil);
}

static void ReleaseHalfFloatBuffer(void *info, const void *data, size_t size) {
  free((void *)data);
}

@end
