//
//  CEFBrowserController.h
//  Sonrisa
//
//  One instance wraps a single CEF browser (one tab). Pure Obj-C interface so
//  it is usable from Swift via the bridging header.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CEFBrowserController : NSObject

/// Creates the container view immediately and asynchronously creates the CEF
/// browser inside it, navigating to `url`.
- (instancetype)initWithURL:(NSString *)url;

/// Like initWithURL:, but `incognito` browsers share one in-memory (off the
/// record) request context: no cookies, cache, or storage touch disk, and it
/// all evaporates when the app quits.
- (instancetype)initWithURL:(NSString *)url incognito:(BOOL)incognito;

/// Whether this browser runs in the incognito request context.
@property (nonatomic, readonly) BOOL incognito;

/// Per-browser ad blocking (effective only while the global blocklist is
/// enabled). Defaults to YES.
@property (nonatomic) BOOL adblockEnabled;

/// The AppKit view that hosts the Chromium content. Embed this in the UI.
@property (nonatomic, readonly) NSView *containerView;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoad;

/// In-page find. `findNext` continues from the current match.
- (void)findInPage:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
/// Ends the find session and clears highlights.
- (void)stopFinding;

/// Page zoom. Delta is in CEF zoom levels (~20% per step); 0 resets.
- (void)zoomBy:(double)delta;
- (void)zoomReset;

/// Opens the native print dialog for the current page.
- (void)printPage;

/// Opens native Chromium DevTools in a separate window (all panels).
/// NOTE: chrome-style CEF crashes on ShowDevTools with a SetAsChild window
/// or a non-empty inspect point — never add either back. Docked (sidebar)
/// DevTools instead embed the remote-debugging frontend via
/// `fetchDevToolsTargetID:` in a regular child browser.
- (void)showDevToolsInWindow;
- (void)closeDevTools;
- (BOOL)hasDevTools;

/// Resolves this browser's DevTools-protocol target id (Target.getTargetInfo
/// over the per-browser DevTools channel). `completion` runs on the main
/// thread with the id, or nil if the browser is gone / the call failed.
/// Build the docked frontend URL as
/// http://127.0.0.1:9222/devtools/inspector.html?ws=127.0.0.1:9222/devtools/page/<id>
- (void)fetchDevToolsTargetID:(void (^)(NSString *_Nullable targetID))completion;

/// Evaluates JavaScript in this browser's page over the DevTools protocol
/// (Runtime.evaluate). Fire-and-forget. Works where ExecuteJavaScript is a
/// chrome-style no-op; used to configure the embedded DevTools frontend.
- (void)evaluateViaDevToolsProtocol:(NSString *)javaScript
    NS_SWIFT_NAME(evaluate(viaDevToolsProtocol:));

/// "Inspect Element" chosen in the page context menu at the given
/// view-relative DIP coordinates. The app opens DevTools per the placement
/// setting. (Coordinates are currently unused — inspect-at-point crashes
/// chrome-style ShowDevTools.)
@property (nonatomic, copy, nullable) void (^onInspectElementRequested)(int x, int y);
/// Reloads bypassing the HTTP cache (⇧⌘R).
- (void)reloadIgnoringCache;

/// Tab audio mute.
- (BOOL)isAudioMuted;
- (void)setAudioMuted:(BOOL)muted;

/// The renderer process died (crash or kill). Offer a reload UI.
@property (nonatomic, copy, nullable) void (^onRenderProcessCrashed)(void);

/// The page entered/left HTML5 fullscreen (e.g. a video player). The app
/// should hide its chrome and take the window fullscreen (and back).
@property (nonatomic, copy, nullable) void (^onFullscreenModeChanged)(BOOL fullscreen);

/// Tears down the underlying CEF browser. Call before releasing the tab.
- (void)close;

// Callbacks are always delivered on the main thread.

/// Page title changed.
@property (nonatomic, copy, nullable) void (^onTitleChanged)(NSString *title);
/// Committed URL changed (e.g. navigation, redirect).
@property (nonatomic, copy, nullable) void (^onURLChanged)(NSString *url);
/// Loading state changed, with updated back/forward availability.
@property (nonatomic, copy, nullable) void (^onLoadingStateChanged)(BOOL isLoading, BOOL canGoBack, BOOL canGoForward);
/// A favicon finished downloading through the page's own network context
/// (privacy-safe — no third-party favicon service). `host` identifies the site.
@property (nonatomic, copy, nullable) void (^onFaviconReady)(NSString *host, NSData *pngData);
/// The page requested a popup / new window (middle-click, window.open,
/// target=_blank). The popup itself is suppressed; open `url` in a new tab.
@property (nonatomic, copy, nullable) void (^onPopupRequested)(NSString *url);
/// The page closed itself (JS window.close()). Close the owning tab; CEF's
/// default handling would performClose: the whole app window instead.
@property (nonatomic, copy, nullable) void (^onPageRequestedClose)(void);

/// Progress for a download started in this browser. Files are saved to
/// ~/Downloads with a unique name; `path` is the final destination.
@property (nonatomic, copy, nullable) void (^onDownloadUpdated)(
    uint32_t downloadID, NSString *path, int64_t receivedBytes,
    int64_t totalBytes, BOOL isComplete, BOOL isCanceledOrInterrupted);

/// The page asked for a sensitive capability (camera, microphone, location,
/// notifications, …). `permissions` is a human-readable list. Call
/// `completion(YES)` to allow. Always invoked on the main thread.
@property (nonatomic, copy, nullable) void (^onPermissionRequested)(
    NSString *origin, NSString *permissions, void (^completion)(BOOL allow));

/// The server asked for HTTP basic/digest credentials. Call `completion` with
/// the entered credentials, or (nil, nil) to cancel. Always invoked on the
/// main thread.
@property (nonatomic, copy, nullable) void (^onAuthRequested)(
    NSString *host, int port, NSString *realm,
    void (^completion)(NSString *_Nullable username, NSString *_Nullable password));

// MARK: Password autofill
//
// The injected autofill script talks to the app through these callbacks.
// `host` is derived from the frame's committed URL (never from page-supplied
// data) and is only forwarded for https:// pages (plus http://localhost).

/// A login form was found; return the saved credentials for `host` as an array
/// of @{@"username": ..., @"password": ...} dictionaries (or nil/empty).
@property (nonatomic, copy, nullable)
    NSArray<NSDictionary<NSString *, NSString *> *> * (^onPasswordsRequested)(NSString *host);
/// A login form was submitted with the given values; offer to save them.
@property (nonatomic, copy, nullable)
    void (^onPasswordSubmitted)(NSString *host, NSString *username, NSString *password);

// MARK: Form autocomplete (non-password fields)

/// Previously submitted values for `field` on `host`, most recent first.
@property (nonatomic, copy, nullable)
    NSArray<NSString *> * (^onFormValuesRequested)(NSString *host, NSString *field);
/// A non-password form field was submitted with `value`; remember it.
@property (nonatomic, copy, nullable)
    void (^onFormValueSubmitted)(NSString *host, NSString *field, NSString *value);

@end

// MARK: - Ad/tracker blocking (global, thread-safe)

#ifdef __cplusplus
extern "C" {
#endif

/// Loads a hosts-format blocklist ("0.0.0.0 domain" or bare "domain" lines)
/// into the in-memory block set. Safe to call from any thread.
void SonrisaAdblockLoadHostsFile(NSString *path);
void SonrisaAdblockSetEnabled(BOOL enabled);
BOOL SonrisaAdblockIsEnabled(void);
/// Number of hosts currently loaded.
NSUInteger SonrisaAdblockHostCount(void);
/// Requests blocked since launch.
NSUInteger SonrisaAdblockBlockedCount(void);

// MARK: - Deeplink schemes (main thread)

/// Custom URL schemes (lowercase, no colon) the browser may hand to the OS
/// to open the matching Mac app. Replaces the previous set.
void SonrisaDeeplinkSetAllowedSchemes(NSArray<NSString *> *schemes);
BOOL SonrisaDeeplinkIsSchemeAllowed(NSString *_Nullable scheme);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
