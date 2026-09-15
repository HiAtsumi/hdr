#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@interface HdrVideoEncoderPlugin : NSObject <FlutterPlugin>
@end
