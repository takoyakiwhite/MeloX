#import "MXPrivateRuntime.h"

#import <objc/message.h>
#import <objc/runtime.h>

static const char *MXSkipTypeQualifiers(const char *type) {
    if (type == NULL) {
        return NULL;
    }
    while (*type == 'r' || *type == 'n' || *type == 'N'
           || *type == 'o' || *type == 'O' || *type == 'R'
           || *type == 'V') {
        type++;
    }
    return type;
}

static BOOL MXTypeEquals(const char *type, const char *expected) {
    type = MXSkipTypeQualifiers(type);
    return type != NULL && strcmp(type, expected) == 0;
}

static BOOL MXTypeIsObject(const char *type) {
    type = MXSkipTypeQualifiers(type);
    // Blocks use @? but are not interchangeable with Objective-C object
    // setters for this private ABI.
    return type != NULL && type[0] == '@' && type[1] != '?';
}

static BOOL MXMethodHasCommonSetterABI(Method method) {
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *receiverType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    BOOL isValid = MXTypeEquals(returnType, "v")
        && MXTypeIsObject(receiverType)
        && MXTypeEquals(selectorType, ":");
    free(returnType);
    free(receiverType);
    free(selectorType);
    return isValid;
}

static Method MXValidatedSetter(
    id object,
    NSString *selectorName,
    const char *valueType,
    BOOL acceptsObject
) {
    if (object == nil || selectorName.length == 0) {
        return NULL;
    }

    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NULL;
    }

    Method method = class_getInstanceMethod([object class], selector);
    if (!MXMethodHasCommonSetterABI(method)) {
        return NULL;
    }

    char *argumentType = method_copyArgumentType(method, 2);
    BOOL isValid = acceptsObject
        ? MXTypeIsObject(argumentType)
        : MXTypeEquals(argumentType, valueType);
    free(argumentType);
    return isValid ? method : NULL;
}

id _Nullable MXTryCreatePrivateInstance(NSString *className) {
    @try {
        Class objectClass = NSClassFromString(className);
        if (objectClass == Nil) {
            return nil;
        }

        Method initializer = class_getInstanceMethod(
            objectClass,
            @selector(init)
        );
        if (initializer == NULL
            || method_getNumberOfArguments(initializer) != 2) {
            return nil;
        }

        char *returnType = method_copyReturnType(initializer);
        char *receiverType = method_copyArgumentType(initializer, 0);
        char *selectorType = method_copyArgumentType(initializer, 1);
        BOOL isValid = MXTypeIsObject(returnType)
            && MXTypeIsObject(receiverType)
            && MXTypeEquals(selectorType, ":");
        free(returnType);
        free(receiverType);
        free(selectorType);
        if (!isValid) {
            return nil;
        }

        return [[objectClass alloc] init];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

BOOL MXTrySetPrivateObject(
    id object,
    NSString *selectorName,
    id _Nullable value
) {
    @try {
        Method method = MXValidatedSetter(
            object,
            selectorName,
            NULL,
            YES
        );
        if (method == NULL) {
            return NO;
        }

        SEL selector = NSSelectorFromString(selectorName);
        typedef void (*ObjectSetter)(id, SEL, id);
        ObjectSetter setter = (ObjectSetter)method_getImplementation(method);
        setter(object, selector, value);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL MXTrySetPrivateDouble(
    id object,
    NSString *selectorName,
    double value
) {
    @try {
        Method method = MXValidatedSetter(
            object,
            selectorName,
            "d",
            NO
        );
        if (method == NULL) {
            return NO;
        }

        SEL selector = NSSelectorFromString(selectorName);
        typedef void (*DoubleSetter)(id, SEL, double);
        DoubleSetter setter = (DoubleSetter)method_getImplementation(method);
        setter(object, selector, value);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

BOOL MXTrySetPrivateBool(
    id object,
    NSString *selectorName,
    BOOL value
) {
    @try {
        Method boolMethod = MXValidatedSetter(
            object,
            selectorName,
            "B",
            NO
        );
        Method charMethod = boolMethod == NULL
            ? MXValidatedSetter(object, selectorName, "c", NO)
            : NULL;
        Method method = boolMethod != NULL ? boolMethod : charMethod;
        if (method == NULL) {
            return NO;
        }

        SEL selector = NSSelectorFromString(selectorName);
        if (boolMethod != NULL) {
            typedef void (*BoolSetter)(id, SEL, BOOL);
            BoolSetter setter = (BoolSetter)method_getImplementation(method);
            setter(object, selector, value);
        } else {
            typedef void (*CharSetter)(id, SEL, signed char);
            CharSetter setter = (CharSetter)method_getImplementation(method);
            setter(object, selector, value ? 1 : 0);
        }
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

#pragma mark - Messages lyric rich-link injection

static BOOL MXMethodHasObjectArguments(
    Method method,
    unsigned int objectArgumentCount,
    BOOL returnsObject
) {
    if (method == NULL
        || method_getNumberOfArguments(method) != objectArgumentCount + 2) {
        return NO;
    }

    char *returnType = method_copyReturnType(method);
    char *receiverType = method_copyArgumentType(method, 0);
    char *selectorType = method_copyArgumentType(method, 1);
    BOOL isValid = (returnsObject
                    ? MXTypeIsObject(returnType)
                    : MXTypeEquals(returnType, "v"))
        && MXTypeIsObject(receiverType)
        && MXTypeEquals(selectorType, ":");
    free(returnType);
    free(receiverType);
    free(selectorType);

    for (unsigned int index = 0;
         isValid && index < objectArgumentCount;
         index++) {
        char *argumentType = method_copyArgumentType(method, index + 2);
        isValid = MXTypeIsObject(argumentType);
        free(argumentType);
    }
    return isValid;
}

id _Nullable MXTryCreatePrivatePlatformImage(
    UIImage *platformImage
) {
    @try {
        if (platformImage == nil) {
            return nil;
        }

        Class imageClass = NSClassFromString(@"LPImage");
        SEL initializerSelector = NSSelectorFromString(
            @"initWithPlatformImage:"
        );
        if (imageClass == Nil) {
            return nil;
        }

        Method initializer = class_getInstanceMethod(
            imageClass,
            initializerSelector
        );
        if (!MXMethodHasObjectArguments(initializer, 1, YES)) {
            return nil;
        }

        id instance = [imageClass alloc];
        typedef id _Nullable (*PlatformImageInitializer)(
            id,
            SEL,
            UIImage *
        );
        PlatformImageInitializer invoke =
            (PlatformImageInitializer)method_getImplementation(initializer);
        return invoke(instance, initializerSelector, platformImage);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static Method MXValidatedObjectMethod(
    id object,
    SEL selector,
    unsigned int objectArgumentCount,
    BOOL returnsObject
) {
    if (object == nil
        || selector == NULL
        || ![object respondsToSelector:selector]) {
        return NULL;
    }
    Method method = class_getInstanceMethod([object class], selector);
    return MXMethodHasObjectArguments(
        method,
        objectArgumentCount,
        returnsObject
    ) ? method : NULL;
}

/// A successful return may still place nil in `value`; nil is a valid value
/// for getters such as `body`, `URL`, and `originalURL`.
static BOOL MXTryGetObject(id object, SEL selector, id _Nullable *value) {
    @try {
        Method method = MXValidatedObjectMethod(object, selector, 0, YES);
        if (method == NULL || value == NULL) {
            return NO;
        }

        typedef id _Nullable (*ObjectGetter)(id, SEL);
        ObjectGetter getter = (ObjectGetter)method_getImplementation(method);
        *value = getter(object, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL MXTryInvokeObjectPair(
    id object,
    SEL selector,
    id firstValue,
    id secondValue
) {
    @try {
        Method method = MXValidatedObjectMethod(object, selector, 2, NO);
        if (method == NULL) {
            return NO;
        }

        typedef void (*ObjectPairInvocation)(id, SEL, id, id);
        ObjectPairInvocation invocation =
            (ObjectPairInvocation)method_getImplementation(method);
        invocation(object, selector, firstValue, secondValue);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static Method MXValidatedSuperPrepareMethod(void) {
    SEL selector = NSSelectorFromString(@"_prepareActivity:");
    Method method = class_getInstanceMethod(
        [UIActivityViewController class],
        selector
    );
    return MXMethodHasObjectArguments(method, 1, NO) ? method : NULL;
}

BOOL MXCanUsePrivateLyricsActivityViewController(void) {
    @try {
        return MXValidatedSuperPrepareMethod() != NULL;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL MXTryPrepareActivityUsingSuperclass(
    MXPrivateLyricsActivityViewController *controller,
    id activity
) {
    @try {
        SEL selector = NSSelectorFromString(@"_prepareActivity:");
        if (MXValidatedSuperPrepareMethod() == NULL) {
            return NO;
        }

        struct objc_super superInfo = {
            .receiver = controller,
            .super_class = [UIActivityViewController class],
        };
        typedef void (*SuperPrepareInvocation)(
            struct objc_super *,
            SEL,
            id
        );
        SuperPrepareInvocation invocation =
            (SuperPrepareInvocation)objc_msgSendSuper;
        invocation(&superInfo, selector, activity);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSURL * _Nullable MXContentURLFromComposer(id composer) {
    id contentURLs = nil;
    if (!MXTryGetObject(
            composer,
            NSSelectorFromString(@"contentURLs"),
            &contentURLs
        )
        || ![contentURLs isKindOfClass:[NSArray class]]) {
        return nil;
    }

    id firstValue = [(NSArray *)contentURLs firstObject];
    if ([firstValue isKindOfClass:[NSURL class]]) {
        return firstValue;
    }
    if ([firstValue isKindOfClass:[NSString class]]) {
        return [NSURL URLWithString:firstValue];
    }
    return nil;
}

static void MXRestoreLinkMetadataURLs(
    id metadata,
    id _Nullable previousURL,
    id _Nullable previousOriginalURL
) {
    MXTrySetPrivateObject(metadata, @"setURL:", previousURL);
    MXTrySetPrivateObject(
        metadata,
        @"setOriginalURL:",
        previousOriginalURL
    );
}

/// Any failed probe exits after UIKit's superclass preparation. Runtime
/// mutation is rolled back where possible, so Messages keeps its normal share
/// behavior rather than being left in a half-configured lyric state.
static void MXTryInjectLyricsRichLink(
    id activity,
    id metadata
) {
    id previousURL = nil;
    id previousOriginalURL = nil;
    id previousBody = nil;
    id composer = nil;
    BOOL changedMetadataURLs = NO;
    BOOL clearedBody = NO;

    @try {
        id activityType = nil;
        if (!MXTryGetObject(
                activity,
                @selector(activityType),
                &activityType
            )
            || ![activityType isEqual:UIActivityTypeMessage]) {
            return;
        }

        if (!MXTryGetObject(
                activity,
                NSSelectorFromString(@"messageComposeViewController"),
                &composer
            )
            || composer == nil) {
            return;
        }

        NSURL *contentURL = MXContentURLFromComposer(composer);
        if (contentURL == nil
            || !MXTryGetObject(metadata, @selector(URL), &previousURL)
            || !MXTryGetObject(
                metadata,
                @selector(originalURL),
                &previousOriginalURL
            )
            || !MXTryGetObject(composer, @selector(body), &previousBody)) {
            return;
        }

        // Validate all mutating private endpoints before changing either the
        // composer or metadata. The invocation helpers validate again at use.
        if (MXValidatedSetter(
                composer,
                @"setBody:",
                NULL,
                YES
            ) == NULL
            || MXValidatedObjectMethod(
                composer,
                NSSelectorFromString(
                    @"addRichLinkData:withWebpageURL:"
                ),
                2,
                NO
            ) == NULL
            || MXValidatedObjectMethod(
                metadata,
                NSSelectorFromString(@"dataRepresentation"),
                0,
                YES
            ) == NULL) {
            return;
        }

        if (!MXTrySetPrivateObject(metadata, @"setURL:", contentURL)
            || !MXTrySetPrivateObject(
                metadata,
                @"setOriginalURL:",
                contentURL
            )) {
            MXRestoreLinkMetadataURLs(
                metadata,
                previousURL,
                previousOriginalURL
            );
            return;
        }
        changedMetadataURLs = YES;

        id dataRepresentation = nil;
        if (!MXTryGetObject(
                metadata,
                NSSelectorFromString(@"dataRepresentation"),
                &dataRepresentation
            )
            || ![dataRepresentation isKindOfClass:[NSData class]]) {
            MXRestoreLinkMetadataURLs(
                metadata,
                previousURL,
                previousOriginalURL
            );
            return;
        }

        if (!MXTrySetPrivateObject(composer, @"setBody:", nil)) {
            MXRestoreLinkMetadataURLs(
                metadata,
                previousURL,
                previousOriginalURL
            );
            return;
        }
        clearedBody = YES;

        if (!MXTryInvokeObjectPair(
                composer,
                NSSelectorFromString(
                    @"addRichLinkData:withWebpageURL:"
                ),
                dataRepresentation,
                contentURL
            )) {
            MXTrySetPrivateObject(composer, @"setBody:", previousBody);
            MXRestoreLinkMetadataURLs(
                metadata,
                previousURL,
                previousOriginalURL
            );
            return;
        }
    } @catch (__unused NSException *exception) {
        if (clearedBody) {
            MXTrySetPrivateObject(composer, @"setBody:", previousBody);
        }
        if (changedMetadataURLs) {
            MXRestoreLinkMetadataURLs(
                metadata,
                previousURL,
                previousOriginalURL
            );
        }
    }
}

@interface MXPrivateLyricsActivityViewController ()

@property(nonatomic, strong) id lyricMetadata;

@end


@implementation MXPrivateLyricsActivityViewController

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(nullable NSArray<__kindof UIActivity *> *)applicationActivities
                         lyricMetadata:(id)lyricMetadata {
    self = [super initWithActivityItems:activityItems
                 applicationActivities:applicationActivities];
    if (self != nil) {
        _lyricMetadata = lyricMetadata;
    }
    return self;
}

- (instancetype)initWithActivityItems:(NSArray *)activityItems
                applicationActivities:(nullable NSArray<__kindof UIActivity *> *)applicationActivities {
    return [self initWithActivityItems:activityItems
                applicationActivities:applicationActivities
                         lyricMetadata:[NSObject new]];
}

// Deliberately declared only here: importing a private UIKit header would bind
// the app to an SDK-private declaration instead of the checked runtime ABI.
- (void)_prepareActivity:(id)activity {
    if (!MXTryPrepareActivityUsingSuperclass(self, activity)) {
        return;
    }
    MXTryInjectLyricsRichLink(activity, self.lyricMetadata);
}

@end


UIActivityViewController * _Nullable
MXCreatePrivateLyricsActivityViewController(
    NSArray *activityItems,
    id lyricMetadata
) {
    @try {
        if (activityItems.count == 0
            || lyricMetadata == nil
            || !MXCanUsePrivateLyricsActivityViewController()) {
            return nil;
        }
        return [[MXPrivateLyricsActivityViewController alloc]
            initWithActivityItems:activityItems
            applicationActivities:nil
            lyricMetadata:lyricMetadata];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}
