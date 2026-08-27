//
//  CEFBrowserRegistry.h
//  Sonrisa
//
//  Main-thread registry of live CEF browsers, used to sequence app shutdown:
//  CefShutdown() fatally asserts when any browser is still alive, so quit must
//  close every browser and wait for each OnBeforeClose before shutting down.
//  Implemented in CEFBrowserController.mm; consumed by CEFRuntime.mm.
//

#ifdef __cplusplus
extern "C" {
#endif

/// Number of CEF browsers that have been created and not yet fully closed.
int SonrisaLiveBrowserCount(void);

/// Force-closes every live browser (asynchronous; each browser's
/// OnBeforeClose fires on a later message-loop turn).
void SonrisaCloseAllBrowsers(void);

/// Registers a callback invoked (on the main thread, from inside CEF's
/// OnBeforeClose) when the last live browser has closed.
void SonrisaSetAllBrowsersClosedCallback(void (*callback)(void));

/// True while CefDoMessageLoopWork() is on the stack. A terminate: that
/// arrives mid-pump was initiated by CEF itself (chrome-style runtime quits
/// the app when the last browser closes), not by the user.
int SonrisaCEFIsPumping(void);

#ifdef __cplusplus
}
#endif
