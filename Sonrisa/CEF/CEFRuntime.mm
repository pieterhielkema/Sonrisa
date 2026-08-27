//
//  CEFRuntime.mm
//  Sonrisa
//
//  Initializes the Chromium Embedded Framework using the single-executable
//  model and drives its message loop from the Cocoa main run loop.
//

#import "CEFRuntime.h"
#import "CEFBrowserRegistry.h"
#import <AppKit/AppKit.h>

#include <crt_externs.h>

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_cookie.h"
#include "include/cef_request_context.h"
#include "include/wrapper/cef_library_loader.h"

// The app ships its own host-scoped form/password autofill (FormDataStore,
// password store + injected dropdown UI, built when Chromium's native popup
// couldn't render under chrome-style CEF). The native popup renders again on
// current CEF, so both would appear on the same input — turn the native
// side off. Shared by the global context (below) and the incognito context
// (CEFBrowserController.mm). UI thread only.
void SonrisaDisableNativeAutofill(CefRefPtr<CefRequestContext> context) {
    if (!context) {
        return;
    }
    CefRefPtr<CefValue> off = CefValue::Create();
    off->SetBool(false);
    CefString error;
    for (const char* pref : {"autofill.profile_enabled",
                             "autofill.credit_card_enabled",
                             "credentials_enable_service"}) {
        if (!context->SetPreference(pref, off, error)) {
            NSLog(@"[Sonrisa] SetPreference %s failed: %s", pref,
                  error.ToString().c_str());
        }
    }
}

namespace {

/// Path to the CEF framework binary inside the app bundle's Frameworks
/// directory (placed there by scripts/embed_cef.sh). Override with the
/// SONRISA_CEF_FRAMEWORK env var.
NSString* FrameworkPath() {
    const char* env = getenv("SONRISA_CEF_FRAMEWORK");
    if (env && strlen(env) > 0) {
        return [NSString stringWithUTF8String:env];
    }
    return [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:
            @"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
}

/// Path to the helper executable that CEF launches for sub-processes.
NSString* HelperExecutablePath() {
    return [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:
            @"Sonrisa Helper.app/Contents/MacOS/Sonrisa Helper"];
}

bool gFrameworkLoaded = false;

bool LoadFrameworkOnce() {
    if (gFrameworkLoaded) {
        return true;
    }
    NSString* path = FrameworkPath();
    if (cef_load_library([path UTF8String])) {
        gFrameworkLoaded = true;
        return true;
    }
    NSLog(@"[Sonrisa] cef_load_library failed for %@", path);
    return false;
}

// MARK: External message pump
//
// CEF requests wake-ups via OnScheduleMessagePumpWork (from arbitrary
// threads). Relying on those callbacks alone is fragile — a single dropped
// wake-up stalls Chromium's UI thread (white pages, no network). So the
// on-demand dispatches are backed by a repeating run-loop timer in common
// modes, which also keeps CEF alive during window resize and menu tracking.

CFRunLoopTimerRef gPumpTimer = nullptr;

// CefDoMessageLoopWork() must never run re-entrantly: while it processes work
// CEF can spin a nested run loop / drain the main dispatch queue, which would
// fire the pump timer or a queued SchedulePumpWork block and call it again.
// A nested call corrupts Chromium's UI-thread state and crashes deep in V8
// (EXC_BAD_ACCESS in CefDoMessageLoopWork). Coalesce instead: if a pump is
// already in progress, skip — the outer pump will pick the work up. Also stop
// pumping once shutdown has begun, so no work runs against a torn-down browser.
bool gPumping = false;

// Shutdown sequencing. Two invariants, both fatal if violated:
//   1. CefShutdown() must not run while CefDoMessageLoopWork() is on the stack
//      (terminate: can fire mid-pump from CEF's nested run loop).
//   2. CefShutdown() must not run while any browser is still alive
//      (CEF fatal-checks -> SIGTRAP).
// So quit is staged: close every browser (pump keeps running so their
// OnBeforeClose can fire), then latch gShutdownPending, then run CefShutdown
// only once no pump is on the stack.
bool gClosingBrowsers = false;   // quit started; browsers closing, keep pumping
bool gShutdownPending = false;   // all browsers gone; CefShutdown when unwound
bool gShutdownDone = false;
bool gInitialized = false;
// This launch handed off to an already-running instance; the app must
// forward its URLs and exit instead of showing UI.
static BOOL gRelaunchHandoff = NO;
void (^gShutdownCompletion)(void) = nil;

// CefInitialize() returns before the Chrome runtime finishes its async startup
// (external message pump). Creating a browser before OnContextInitialized fires
// crashes intermittently deep inside CefBrowserHost::CreateBrowser (null deref,
// EXC_BAD_ACCESS at 0x8) — the race is timing-dependent, so it only hits on
// fast launches. Queue all browser creation until the context is ready.
bool gContextInitialized = false;
NSMutableArray<void (^)(void)>* gContextInitQueue = nil;

void StopPumpTimer();  // forward decl (defined below)

void PerformShutdownIfSafe() {
    if (!gShutdownPending || gPumping || gShutdownDone) {
        return;  // nothing latched, or still inside a pump — retry after unwind
    }
    gShutdownPending = false;
    gShutdownDone = true;
    StopPumpTimer();
    if (gInitialized) {
        CefShutdown();
        gInitialized = false;
    }
    if (gShutdownCompletion) {
        void (^completion)(void) = gShutdownCompletion;
        gShutdownCompletion = nil;
        completion();
    }
}

void PumpCEF() {
    if (gPumping || gShutdownDone) {
        return;
    }
    if (gShutdownPending) {
        PerformShutdownIfSafe();  // no new work; just finish the shutdown
        return;
    }
    gPumping = true;
    CefDoMessageLoopWork();
    gPumping = false;
    // If quit latched the shutdown mid-pump (last OnBeforeClose, or terminate:
    // fired from CEF's nested loop), it is safe to run now that we unwound.
    PerformShutdownIfSafe();
}

/// Registered with the browser registry; runs inside the last OnBeforeClose.
void OnAllBrowsersClosed() {
    if (!gClosingBrowsers) {
        return;  // normal tab churn hit zero browsers; not quitting
    }
    gClosingBrowsers = false;
    gShutdownPending = true;
    // We are inside a pump; the trailing PerformShutdownIfSafe in PumpCEF will
    // finish. Poke the main queue as a fallback in case no pump is on stack.
    dispatch_async(dispatch_get_main_queue(), ^{
        PerformShutdownIfSafe();
    });
}

void StartPumpTimer() {
    if (gPumpTimer) {
        return;
    }
    gPumpTimer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(),
        // 8ms (~120Hz) keeps browser-side work (frame acks, media state,
        // input routing) ahead of 60fps video; 20ms visibly janked playback.
        /*interval=*/0.008, 0, 0, ^(CFRunLoopTimerRef timer) {
            PumpCEF();
        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), gPumpTimer, kCFRunLoopCommonModes);
}

void StopPumpTimer() {
    if (!gPumpTimer) {
        return;
    }
    CFRunLoopTimerInvalidate(gPumpTimer);
    CFRelease(gPumpTimer);
    gPumpTimer = nullptr;
}

void SchedulePumpWork(int64_t delay_ms) {
    if (delay_ms <= 0) {
        // Immediate work: hop to the main thread and pump right away.
        dispatch_async(dispatch_get_main_queue(), ^{
            PumpCEF();
        });
    }
    // Delayed work is covered by the repeating pump timer.
}

/// Minimal CefApp advertising the browser-process handler for the message pump.
class SonrisaCefApp : public CefApp, public CefBrowserProcessHandler {
public:
    SonrisaCefApp() = default;

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        SchedulePumpWork(delay_ms);
    }

    void OnContextInitialized() override {
        // Fires on the UI thread, which is the main thread here (external
        // pump), possibly from inside CefDoMessageLoopWork. Hop to the next
        // main-queue turn so queued CreateBrowser calls never run mid-pump.
        dispatch_async(dispatch_get_main_queue(), ^{
            SonrisaDisableNativeAutofill(CefRequestContext::GetGlobalContext());
            gContextInitialized = true;
            NSArray<void (^)(void)>* queued = gContextInitQueue;
            gContextInitQueue = nil;
            for (void (^block)(void) in queued) {
                block();
            }
        });
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        if (!process_type.empty()) {
            return;  // browser process only
        }
        // Chrome-style CEF exits the app when the last browser closes — it
        // calls -[NSApplication terminate:] from inside the message pump. Our
        // tab model closes the old browser before its replacement finishes
        // creating, so the count transiently hits zero on every last-tab close
        // and CEF yanked the whole app down (the "closing a tab crashes"
        // reports). This switch holds a keep-alive so the browser process
        // never self-terminates; app lifetime stays ours.
        command_line->AppendSwitch("keep-alive-for-test");
#if DEBUG
        // The docked DevTools pane hosts the DevTools web frontend (served by
        // the remote-debugging server) in a regular child browser; its
        // WebSocket back to the server carries an http Origin header that the
        // server rejects unless allowed here. Debug only, like the port.
        command_line->AppendSwitchWithValue("remote-allow-origins",
                                            "http://127.0.0.1:9222");
#endif
    }

    bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine> command_line,
                                     const CefString& current_directory) override {
        // A second app instance launched with the same profile (e.g. a link
        // clicked in another app resolving to the /Applications copy) and
        // handed off to us. Returning true suppresses the default Chrome-UI
        // window. Any URLs on its command line must be routed into an
        // existing window — dropping them here loses the clicked link.
        std::vector<CefString> args;
        command_line->GetArguments(args);
        NSMutableArray<NSString*>* urls = [NSMutableArray array];
        for (const auto& arg : args) {
            NSString* s = [NSString stringWithUTF8String:arg.ToString().c_str()];
            if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) {
                [urls addObject:s];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
            if (urls.count > 0) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"SonrisaOpenURLsFromRelaunch"
                                  object:nil
                                userInfo:@{@"urls" : urls}];
            }
        });
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(SonrisaCefApp);
    DISALLOW_COPY_AND_ASSIGN(SonrisaCefApp);
};

NSString* CacheDirectoryPath() {
    NSArray<NSString*>* dirs =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                            NSUserDomainMask, YES);
    NSString* support = dirs.firstObject ?: NSTemporaryDirectory();
    NSString* path = [support stringByAppendingPathComponent:@"Sonrisa/CEF"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return path;
}

}  // namespace

int SonrisaCEFIsPumping(void) {
    return gPumping ? 1 : 0;
}

void SonrisaRunWhenCefContextInitialized(void (^block)(void)) {
    if (gContextInitialized) {
        block();
        return;
    }
    if (!gContextInitQueue) {
        gContextInitQueue = [NSMutableArray array];
    }
    [gContextInitQueue addObject:[block copy]];
}

@implementation CEFRuntime

+ (int)executeSubprocess {
    if (!LoadFrameworkOnce()) {
        return 1;
    }
    CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
    return CefExecuteProcess(main_args, nullptr, nullptr);
}

+ (BOOL)isRelaunchHandoff {
    return gRelaunchHandoff;
}

+ (BOOL)initializeBrowserProcess {
    if (gInitialized) {
        return YES;
    }
    if (!LoadFrameworkOnce()) {
        return NO;
    }

    CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());

    CefSettings settings;
    settings.no_sandbox = true;               // App Sandbox is disabled for this target.
    settings.external_message_pump = true;    // Required on macOS to share the Cocoa run loop.
    settings.log_severity = LOGSEVERITY_WARNING;
#if DEBUG
    // DevTools protocol on localhost, Debug only (any local process can
    // drive the browser through it). The docked DevTools pane embeds the
    // server-hosted frontend (chrome-style ShowDevTools crashes when given a
    // SetAsChild window), so the sidebar placement exists only in Debug
    // builds; Release falls back to the native DevTools window.
    settings.remote_debugging_port = 9222;
#endif

    CefString(&settings.browser_subprocess_path)
        .FromString([HelperExecutablePath() UTF8String]);
    CefString(&settings.root_cache_path)
        .FromString([CacheDirectoryPath() UTF8String]);

    CefRefPtr<SonrisaCefApp> app = new SonrisaCefApp();
    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
        // Another Sonrisa instance already owns the profile; this launch has
        // handed off to it. Don't exit yet: a link click that launched this
        // instance arrives as a GetURL Apple Event only AFTER launch
        // finishes. Mark handoff mode — the app delegate finishes launching
        // headless, forwards the URLs from application:openURLs:, then exits.
        const int exit_code = CefGetExitCode();
        NSLog(@"[Sonrisa] CefInitialize declined (exit code %d) — an "
              @"already-running instance owns the profile; handoff mode.",
              exit_code);
        gRelaunchHandoff = YES;
        // URLs passed as plain arguments (open -a … <url>, CLI) don't come
        // through the Apple Event — forward them right away.
        NSMutableArray<NSString*>* urls = [NSMutableArray array];
        for (NSString* arg in NSProcessInfo.processInfo.arguments) {
            if ([arg hasPrefix:@"http://"] || [arg hasPrefix:@"https://"]) {
                [urls addObject:arg];
            }
        }
        if (urls.count > 0) {
            [NSDistributedNotificationCenter.defaultCenter
                postNotificationName:@"com.timodogroup.Sonrisa.relaunch-urls"
                              object:[urls componentsJoinedByString:@"\n"]
                            userInfo:nil
                  deliverImmediately:YES];
        }
        return NO;
    }

    StartPumpTimer();
    gInitialized = true;
    return YES;
}

+ (void)shutdown {
    // Legacy synchronous path; safe only when no pump is on the stack and all
    // browsers are already closed. Prefer beginShutdownWithCompletion:.
    if (!gInitialized || gShutdownDone) {
        return;
    }
    gShutdownDone = true;
    StopPumpTimer();
    CefShutdown();
    gInitialized = false;
}

+ (void)beginShutdownWithCompletion:(void (^)(void))completion {
    if (!gInitialized || gShutdownDone) {
        if (completion) completion();
        return;
    }
    gShutdownCompletion = [completion copy];
    SonrisaSetAllBrowsersClosedCallback(&OnAllBrowsersClosed);

    if (SonrisaLiveBrowserCount() == 0) {
        // Nothing to close; latch shutdown for the first safe moment.
        gShutdownPending = true;
        if (gPumping) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PerformShutdownIfSafe();
            });
        } else {
            PerformShutdownIfSafe();
        }
        return;
    }

    // Close every browser; the pump keeps running so each OnBeforeClose can
    // fire. The registry's all-closed callback then latches the shutdown.
    gClosingBrowsers = true;
    SonrisaCloseAllBrowsers();

    // Watchdog: individual browser closes routinely don't complete under the
    // external pump (chrome-style + foreign parent view); CefShutdown flushes
    // them all safely once no pump is on the stack. Give graceful close a
    // short head start, then force.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gShutdownDone) {
            NSLog(@"[Sonrisa] Browser close timed out; forcing CefShutdown.");
            gClosingBrowsers = false;
            gShutdownPending = true;
            PerformShutdownIfSafe();
        }
    });
}

+ (void)clearCookies {
    CefRefPtr<CefCookieManager> manager =
        CefCookieManager::GetGlobalManager(nullptr);
    if (manager) {
        manager->DeleteCookies(CefString(), CefString(), nullptr);
    }
}

@end
