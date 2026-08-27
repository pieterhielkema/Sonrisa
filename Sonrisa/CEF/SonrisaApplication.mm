//
//  SonrisaApplication.mm
//  Sonrisa
//
//  Conforms the application object to CEF's CefAppProtocol so Chromium can
//  track whether an event is currently being dispatched (it uses this to
//  decide how to handle nested event loops for menus, dialogs, and dragging).
//

#import "SonrisaApplication.h"
#import "CEFBrowserRegistry.h"
#import "CEFRuntime.h"

#include "include/cef_application_mac.h"

NSNotificationName const SonrisaNavigateBackNotification =
    @"SonrisaNavigateBackNotification";
NSNotificationName const SonrisaNavigateForwardNotification =
    @"SonrisaNavigateForwardNotification";

@interface SonrisaApplication () <CefAppProtocol>
@end

@implementation SonrisaApplication {
    BOOL _handlingSendEvent;
    BOOL _terminating;
}

// Every quit path (⌘Q, menu, AppleScript quit, logout) funnels through
// terminate:. Intercept it here — the SwiftUI delegate adaptor does not
// reliably forward applicationShouldTerminate:, so this is the only hook that
// catches them all. CEF teardown must happen BEFORE normal termination:
// CefShutdown() fatal-checks if any browser is alive, and must not run while
// CefDoMessageLoopWork() is on the stack (terminate: can arrive mid-pump from
// CEF's nested event loops). beginShutdownWithCompletion: closes all browsers,
// waits for their OnBeforeClose, runs CefShutdown once the pump has unwound,
// then we resume the real termination.
- (void)terminate:(id)sender {
    // Chrome-style CEF calls terminate: itself, from inside the message pump,
    // whenever the live browser count hits zero — which happens transiently on
    // every last-tab close because the replacement tab's browser is created
    // asynchronously. That is not a user quit; swallow it. Real quits (⌘Q,
    // menu, AppleScript, logout) never arrive with a pump on the stack.
    if (SonrisaCEFIsPumping() && !_terminating) {
        NSLog(@"[Sonrisa] Ignoring CEF-initiated terminate (zero-browser blip).");
        return;
    }
    if (_terminating) {
        return;  // shutdown already in flight; ignore repeat quits
    }
    _terminating = YES;
    [CEFRuntime beginShutdownWithCompletion:^{
        [super terminate:sender];
    }];
}

- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    // Navigation swipes: trackpad two-finger swipes and mouse drivers (e.g.
    // Logi Options thumb buttons) deliver these. +1 = back, -1 = forward.
    // Tag with the target window so only that window's browser navigates.
    NSWindow *eventWindow = event.window ?: NSApp.keyWindow;
    if (event.type == NSEventTypeSwipe && event.deltaX != 0) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:(event.deltaX > 0
                                      ? SonrisaNavigateBackNotification
                                      : SonrisaNavigateForwardNotification)
                          object:eventWindow];
        return;
    }

    // Mouse buttons 4/5 navigate back/forward (buttonNumber is zero-based).
    if (event.type == NSEventTypeOtherMouseDown) {
        if (event.buttonNumber == 3) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:SonrisaNavigateBackNotification
                              object:eventWindow];
            return;  // Swallowed — don't let the page see it too.
        }
        if (event.buttonNumber == 4) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:SonrisaNavigateForwardNotification
                              object:eventWindow];
            return;
        }
    } else if (event.type == NSEventTypeOtherMouseUp &&
               (event.buttonNumber == 3 || event.buttonNumber == 4)) {
        return;  // Swallow the matching mouse-up as well.
    }

    CefScopedSendingEvent sendingEventScoper;
    [super sendEvent:event];
}

@end
