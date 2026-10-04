#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and catches Objective-C exceptions (which Swift can't).
/// AVFoundation raises these for settings it rejects; without catching them
/// the whole app would quit. Returns nil on success, else the reason.
NSString *_Nullable CDCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
