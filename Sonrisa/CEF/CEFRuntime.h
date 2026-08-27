//
//  CEFRuntime.h
//  Sonrisa
//
//  Objective-C facade over CEF process initialization. Pure Obj-C so it can be
//  imported from Swift through the bridging header.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the lifetime of the Chromium (CEF) runtime for the browser process.
///
/// This app uses CEF's single-executable model: the same binary is relaunched
/// for sub-processes (renderer, GPU, ...). Call `+executeSubprocess` first thing
/// in `main`; if it returns >= 0 the current launch was a sub-process and the
/// process should exit with that code.
@interface CEFRuntime : NSObject

/// Runs `CefExecuteProcess`. Returns the sub-process exit code (>= 0) when the
/// current launch is a CEF sub-process, or -1 for the main browser process.
+ (int)executeSubprocess;

/// Loads the CEF framework and calls `CefInitialize`. Must be called once, on
/// the main thread, before any browser is created. Returns `NO` on failure.
+ (BOOL)initializeBrowserProcess;

/// True when initializeBrowserProcess declined because another instance owns
/// the profile: this launch must forward its URLs (application:openURLs:) to
/// that instance and exit without showing UI.
+ (BOOL)isRelaunchHandoff;

/// Calls `CefShutdown`. Invoke on app termination after all browsers close.
+ (void)shutdown;

/// Begins a pump-safe shutdown: stops the message pump and runs `CefShutdown`
/// once no `CefDoMessageLoopWork()` is on the stack, then invokes `completion`
/// on the main thread. Use from `applicationShouldTerminate:` with
/// `NSTerminateLater` so `CefShutdown` never runs re-entrantly inside a pump
/// (which crashes deep in CEF/V8).
+ (void)beginShutdownWithCompletion:(void (^_Nullable)(void))completion;

/// Deletes all cookies in the default (non-incognito) profile. HTTP cache and
/// site storage stay until the app's cache directory is removed.
+ (void)clearCookies;

@end

/// Runs `block` on the main thread once CEF's `OnContextInitialized` has fired
/// (immediately if it already has). Browser creation MUST go through this:
/// `CefInitialize` returns before the Chrome runtime finishes its async
/// startup, and `CefBrowserHost::CreateBrowser` before that point crashes
/// intermittently deep inside CEF.
void SonrisaRunWhenCefContextInitialized(void (^block)(void));

NS_ASSUME_NONNULL_END
