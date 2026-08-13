#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C exception boundary for optional private framework objects.
/// Every call also validates the complete method ABI before invoking it.
FOUNDATION_EXPORT id _Nullable MXTryCreatePrivateInstance(
    NSString *className
);

/// Creates LinkPresentation's private LPImage only when the observed
/// `initWithPlatformImage:` object initializer still has its exact ABI.
FOUNDATION_EXPORT id _Nullable MXTryCreatePrivatePlatformImage(
    UIImage *platformImage
);

FOUNDATION_EXPORT BOOL MXTrySetPrivateObject(
    id object,
    NSString *selectorName,
    id _Nullable value
);

FOUNDATION_EXPORT BOOL MXTrySetPrivateDouble(
    id object,
    NSString *selectorName,
    double value
);

FOUNDATION_EXPORT BOOL MXTrySetPrivateBool(
    id object,
    NSString *selectorName,
    BOOL value
);

/// A narrowly-scoped activity controller that preserves UIKit's ordinary
/// preparation, then augments Messages with lyric LinkPresentation data when
/// every private runtime method still has the ABI observed in Music.
@interface MXPrivateLyricsActivityViewController : UIActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(nullable NSArray<__kindof UIActivity *> *)applicationActivities
                         lyricMetadata:(id)lyricMetadata NS_DESIGNATED_INITIALIZER;

@end

/// The subclass is never instantiated unless UIKit still exposes the exact
/// superclass `_prepareActivity:` ABI that the override must forward to.
FOUNDATION_EXPORT BOOL MXCanUsePrivateLyricsActivityViewController(void);

/// Returns nil when the capability gate or required input is unavailable.
/// The Swift caller then creates the ordinary SystemShareSheet controller.
FOUNDATION_EXPORT UIActivityViewController * _Nullable
MXCreatePrivateLyricsActivityViewController(
    NSArray *activityItems,
    id lyricMetadata
);

NS_ASSUME_NONNULL_END
