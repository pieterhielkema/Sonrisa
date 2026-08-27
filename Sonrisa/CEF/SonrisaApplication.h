//
//  SonrisaApplication.h
//  Sonrisa
//
//  NSApplication subclass required by CEF. Chromium calls
//  isHandlingSendEvent/setHandlingSendEvent: on the shared application object;
//  without this subclass those calls crash with doesNotRecognizeSelector.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the back/forward mouse buttons (buttons 4/5) are clicked.
extern NSNotificationName const SonrisaNavigateBackNotification;
extern NSNotificationName const SonrisaNavigateForwardNotification;

@interface SonrisaApplication : NSApplication
@end

NS_ASSUME_NONNULL_END
