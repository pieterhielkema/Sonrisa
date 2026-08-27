//
//  CEFBrowserController.mm
//  Sonrisa
//
//  Bridges a single CEF browser to AppKit/SwiftUI. The C++ CefClient and image
//  download callbacks forward everything back to the Obj-C controller, whose
//  block callbacks are consumed from Swift.
//

#import "CEFBrowserController.h"
#import "CEFBrowserRegistry.h"
#import "CEFRuntime.h"

#include <algorithm>
#include <atomic>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_image.h"
#include "include/cef_parser.h"
#include "include/cef_urlrequest.h"
#include "include/wrapper/cef_message_router.h"

// MARK: - Private controller interface used by the C++ layer

@interface CEFBrowserController ()
- (void)cefAttachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)cefDetachBrowser;
- (void)cefTitleChanged:(NSString *)title;
- (void)cefURLChanged:(NSString *)url;
- (void)cefPopupRequested:(NSString *)url;
- (void)cefPageRequestedClose;
- (void)cefInspectElementRequestedAtX:(int)x y:(int)y;
- (void)cefDevToolsResult:(int)messageID targetID:(NSString *_Nullable)targetID;
- (NSWindow *_Nullable)cefScratchCloseWindow;
- (void)cefLoadingChanged:(BOOL)loading back:(BOOL)canBack forward:(BOOL)canForward;
- (void)cefRequestFaviconDownload:(CefRefPtr<CefBrowser>)browser
                             urls:(const std::vector<CefString> &)iconURLs;
- (void)cefTryFaviconURLs:(const std::vector<CefString> &)urls
                  browser:(CefRefPtr<CefBrowser>)browser
                     host:(NSString *)host;
- (void)cefFaviconData:(NSData *)png forHost:(NSString *)host;
- (void)cefDownloadUpdate:(uint32_t)downloadID
                     path:(NSString *)path
                 received:(int64_t)received
                    total:(int64_t)total
                 complete:(BOOL)complete
                 canceled:(BOOL)canceled;
/// Returns NO when no auth handler is installed (caller falls back to CEF's
/// default cancel). May be called from any CEF thread.
- (BOOL)cefAuthRequestHost:(NSString *)host
                      port:(int)port
                     realm:(NSString *)realm
                completion:(void (^)(NSString *, NSString *))completion;
/// Asks the user to allow `permissions` for `origin`; denies when no handler.
- (void)cefPermissionPromptOrigin:(NSString *)origin
                      permissions:(NSString *)permissions
                       completion:(void (^)(BOOL))completion;
- (void)cefRenderProcessCrashed;
- (void)cefFullscreenModeChanged:(BOOL)fullscreen;
@end

// MARK: - Live-browser registry (main thread only; see CEFBrowserRegistry.h)

static std::vector<CefRefPtr<CefBrowser>> gLiveBrowsers;
static void (*gAllBrowsersClosedCallback)(void) = nullptr;

int SonrisaLiveBrowserCount(void) {
    return (int)gLiveBrowsers.size();
}

static NSWindow* DetachIntoScratchWindow(CefRefPtr<CefBrowser> browser);

// Scratch windows for quit-time closes; freed when the registry empties.
static NSMutableArray<NSWindow*>* gQuitScratchWindows = nil;

void SonrisaCloseAllBrowsers(void) {
    if (!gQuitScratchWindows) gQuitScratchWindows = [NSMutableArray array];
    // Copy: OnBeforeClose mutates gLiveBrowsers while these process.
    std::vector<CefRefPtr<CefBrowser>> browsers = gLiveBrowsers;
    for (auto& browser : browsers) {
        // Keep CEF's top-level-window close away from the app window here too.
        NSWindow* scratch = DetachIntoScratchWindow(browser);
        if (scratch) [gQuitScratchWindows addObject:scratch];
        browser->GetHost()->CloseBrowser(true);
    }
}

void SonrisaSetAllBrowsersClosedCallback(void (*callback)(void)) {
    gAllBrowsersClosedCallback = callback;
}

static void RegistryAddBrowser(CefRefPtr<CefBrowser> browser) {
    gLiveBrowsers.push_back(browser);
}

static void RegistryRemoveBrowser(CefRefPtr<CefBrowser> browser) {
    for (auto it = gLiveBrowsers.begin(); it != gLiveBrowsers.end(); ++it) {
        if ((*it)->IsSame(browser)) {
            gLiveBrowsers.erase(it);
            break;
        }
    }
    NSLog(@"[Sonrisa] browser closed; %d still live", (int)gLiveBrowsers.size());
    if (gLiveBrowsers.empty()) {
        gQuitScratchWindows = nil;
        if (gAllBrowsersClosedCallback) {
            gAllBrowsersClosedCallback();
        }
    }
}

namespace {

NSString* ToNSString(const CefString& str) {
    const std::string utf8 = str.ToString();
    return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

// MARK: - Password autofill

/// Host a frame's credentials are keyed under, or "" when the frame must not
/// take part in autofill. Derived from the frame's committed URL — never from
/// page-supplied data — and restricted to https (plus http on localhost, for
/// development). A leading "www." is stripped so www/apex share credentials.
std::string AutofillHostForFrame(CefRefPtr<CefFrame> frame) {
    if (!frame) {
        return "";
    }
    CefURLParts parts;
    if (!CefParseURL(frame->GetURL(), parts)) {
        return "";
    }
    std::string scheme = CefString(&parts.scheme).ToString();
    std::string host = CefString(&parts.host).ToString();
    if (host.empty()) {
        return "";
    }
    const bool secure = scheme == "https";
    const bool local = scheme == "http" && (host == "localhost" || host == "127.0.0.1");
    if (!secure && !local) {
        return "";
    }
    if (host.rfind("www.", 0) == 0) {
        host = host.substr(4);
    }
    return host;
}

// The autofill script itself lives in AutofillScript.h and is injected by
// the renderer helper (helper/helper_main.mm) at OnLoadEnd — browser-process
// ExecuteJavaScript is a silent no-op under the chrome-style runtime.

/// Theme payload for injected page UI (JSON viewer). Viewer chrome is always
/// dark, so dynamic system colors resolve their dark variant regardless of
/// app appearance. Accent read from the same defaults key AppSettings uses.
static std::string SonrisaThemeJSON() {
    NSString* choice = [[NSUserDefaults standardUserDefaults]
                           stringForKey:@"settings.accent"] ?: @"system";
    NSColor* accent = NSColor.controlAccentColor;
    if ([choice isEqualToString:@"orange"]) accent = NSColor.systemOrangeColor;
    else if ([choice isEqualToString:@"blue"]) accent = NSColor.systemBlueColor;
    else if ([choice isEqualToString:@"purple"]) accent = NSColor.systemPurpleColor;
    else if ([choice isEqualToString:@"pink"]) accent = NSColor.systemPinkColor;
    else if ([choice isEqualToString:@"green"]) accent = NSColor.systemGreenColor;

    __block NSColor* rgb = nil;
    [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
        performAsCurrentDrawingAppearance:^{
            rgb = [accent colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        }];
    NSString* hex = rgb
        ? [NSString stringWithFormat:@"#%02X%02X%02X",
              (int)lround(rgb.redComponent * 255),
              (int)lround(rgb.greenComponent * 255),
              (int)lround(rgb.blueComponent * 255)]
        : @"#0A84FF";
    return [[NSString stringWithFormat:@"{\"mode\":\"dark\",\"accent\":\"%@\"}",
                                       hex] UTF8String];
}

/// Browser-process handler for the autofill script's cefQuery messages.
class PasswordQueryHandler : public CefMessageRouterBrowserSide::Handler {
public:
    explicit PasswordQueryHandler(CEFBrowserController* controller)
        : controller_(controller) {}

    bool OnQuery(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int64_t query_id,
                 const CefString& request,
                 bool persistent,
                 CefRefPtr<Callback> callback) override {
        CefRefPtr<CefValue> parsed = CefParseJSON(request, JSON_PARSER_RFC);
        if (!parsed || parsed->GetType() != VTYPE_DICTIONARY) {
            return false;
        }
        CefRefPtr<CefDictionaryValue> dict = parsed->GetDictionary();
        const std::string cmd = dict->GetString("cmd").ToString();

        // Theme for injected page UI (JSON viewer). Not host-gated: answers
        // before the host check because it carries no sensitive data and must
        // work on any page. Persistent queries stay subscribed and get pushed
        // a fresh payload when the accent changes.
        if (cmd == "theme") {
            const std::string json = SonrisaThemeJSON();
            if (persistent) {
                theme_subs_.push_back({query_id, callback});
                EnsureThemeObservers();
                last_theme_json_ = json;
            }
            callback->Success(json);
            return true;
        }

        // The host comes from the frame's real URL; a page cannot request or
        // save credentials for another site.
        const std::string host = AutofillHostForFrame(frame);
        CEFBrowserController* controller = controller_;
        if (host.empty() || !controller) {
            return false;
        }
        NSString* nsHost = [NSString stringWithUTF8String:host.c_str()] ?: @"";

        if (cmd == "get") {
            NSArray<NSDictionary<NSString*, NSString*>*>* creds = nil;
            if (controller.onPasswordsRequested) {
                creds = controller.onPasswordsRequested(nsHost);
            }
            CefRefPtr<CefListValue> list = CefListValue::Create();
            size_t index = 0;
            for (NSDictionary<NSString*, NSString*>* cred in creds) {
                CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
                entry->SetString("username", [(cred[@"username"] ?: @"") UTF8String]);
                entry->SetString("password", [(cred[@"password"] ?: @"") UTF8String]);
                list->SetDictionary(index++, entry);
            }
            CefRefPtr<CefDictionaryValue> root = CefDictionaryValue::Create();
            root->SetList("credentials", list);
            CefRefPtr<CefValue> value = CefValue::Create();
            value->SetDictionary(root);
            callback->Success(CefWriteJSON(value, JSON_WRITER_DEFAULT));
            return true;
        }

        if (cmd == "save") {
            NSString* username = ToNSString(dict->GetString("username"));
            NSString* password = ToNSString(dict->GetString("password"));
            if (password.length > 0 && controller.onPasswordSubmitted) {
                controller.onPasswordSubmitted(nsHost, username, password);
            }
            callback->Success("");
            return true;
        }

        if (cmd == "formget") {
            NSString* field = ToNSString(dict->GetString("field"));
            NSArray<NSString*>* values = nil;
            if (field.length > 0 && controller.onFormValuesRequested) {
                values = controller.onFormValuesRequested(nsHost, field);
            }
            CefRefPtr<CefListValue> list = CefListValue::Create();
            size_t index = 0;
            for (NSString* value in values) {
                list->SetString(index++, [value UTF8String]);
            }
            CefRefPtr<CefDictionaryValue> root = CefDictionaryValue::Create();
            root->SetList("values", list);
            CefRefPtr<CefValue> value = CefValue::Create();
            value->SetDictionary(root);
            callback->Success(CefWriteJSON(value, JSON_WRITER_DEFAULT));
            return true;
        }

        if (cmd == "formsave") {
            NSString* field = ToNSString(dict->GetString("field"));
            NSString* value = ToNSString(dict->GetString("value"));
            if (field.length > 0 && value.length > 0 && controller.onFormValueSubmitted) {
                controller.onFormValueSubmitted(nsHost, field, value);
            }
            callback->Success("");
            return true;
        }

        return false;
    }

    void OnQueryCanceled(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         int64_t query_id) override {
        for (auto it = theme_subs_.begin(); it != theme_subs_.end();) {
            if (it->first == query_id) {
                it = theme_subs_.erase(it);
            } else {
                ++it;
            }
        }
    }

    ~PasswordQueryHandler() override {
        for (id token in theme_observers_) {
            [NSNotificationCenter.defaultCenter removeObserver:token];
        }
    }

private:
    // Registered lazily on the first persistent theme query. Both the accent
    // setting (NSUserDefaultsDidChangeNotification — fires for in-process
    // writes, i.e. the Settings UI; NOT for KVO because the key contains a
    // dot, and not for external `defaults write`) and the system accent
    // (NSSystemColors, matters for choice "system") can change the payload.
    // Observers run on the main queue, which is CEF's UI thread under the
    // external pump, so calling the router callback here is safe. The block
    // captures `this` raw; the destructor removes the observers on that same
    // thread before the handler dies (the owning client is released on the
    // UI thread).
    void EnsureThemeObservers() {
        if (theme_observers_) { return; }
        theme_observers_ = [NSMutableArray array];
        PasswordQueryHandler* handler = this;
        void (^notify)(NSNotification*) = ^(NSNotification*) {
            handler->PushThemeIfChanged();
        };
        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        [theme_observers_
            addObject:[nc addObserverForName:NSUserDefaultsDidChangeNotification
                                      object:nil
                                       queue:NSOperationQueue.mainQueue
                                  usingBlock:notify]];
        [theme_observers_
            addObject:[nc addObserverForName:NSSystemColorsDidChangeNotification
                                      object:nil
                                       queue:NSOperationQueue.mainQueue
                                  usingBlock:notify]];
    }

    void PushThemeIfChanged() {
        if (theme_subs_.empty()) { return; }
        const std::string json = SonrisaThemeJSON();
        if (json == last_theme_json_) { return; }
        last_theme_json_ = json;
        for (auto& sub : theme_subs_) {
            sub.second->Success(json);
        }
    }

    __weak CEFBrowserController* controller_;
    std::vector<std::pair<int64_t, CefRefPtr<Callback>>> theme_subs_;
    std::string last_theme_json_;
    NSMutableArray<id>* theme_observers_ = nil;
    DISALLOW_COPY_AND_ASSIGN(PasswordQueryHandler);
};

// MARK: - Ad/tracker blocking

// The block set is swapped atomically under a mutex; lookups happen on the IO
// thread for every subresource request, so keep the fast path lock-light.
static std::mutex gAdblockMutex;
static std::shared_ptr<std::unordered_set<std::string>> gAdblockHosts =
    std::make_shared<std::unordered_set<std::string>>();
static std::atomic<bool> gAdblockEnabled{false};
static std::atomic<uint64_t> gAdblockBlocked{0};

static bool AdblockMatchesHost(const std::string& host) {
    std::shared_ptr<std::unordered_set<std::string>> hosts;
    {
        std::lock_guard<std::mutex> lock(gAdblockMutex);
        hosts = gAdblockHosts;
    }
    if (hosts->empty()) {
        return false;
    }
    // Exact match, then each parent domain (ads.foo.example.com →
    // foo.example.com → example.com).
    std::string candidate = host;
    while (true) {
        if (hosts->count(candidate)) {
            return true;
        }
        size_t dot = candidate.find('.');
        if (dot == std::string::npos) {
            return false;
        }
        candidate = candidate.substr(dot + 1);
    }
}

namespace {

class SonrisaResourceHandler : public CefResourceRequestHandler {
public:
    explicit SonrisaResourceHandler(bool adblock) : adblock_(adblock) {}

    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback> callback) override {
        if (!adblock_) return RV_CONTINUE;
        CefURLParts parts;
        if (CefParseURL(request->GetURL(), parts)) {
            std::string host = CefString(&parts.host).ToString();
            std::transform(host.begin(), host.end(), host.begin(), ::tolower);
            if (AdblockMatchesHost(host)) {
                gAdblockBlocked.fetch_add(1, std::memory_order_relaxed);
                return RV_CANCEL;
            }
        }
        return RV_CONTINUE;
    }

    // Custom-scheme requests (spotify:, zoommtg:, …). Never let the OS
    // execute directly — for schemes enabled in Settings → Deeplinks the
    // Swift side shows an "Open in <app>?" prompt and opens on confirm.
    void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefRequest> request,
                             bool& allow_os_execution) override {
        allow_os_execution = false;
        std::string url = request->GetURL().ToString();
        size_t colon = url.find(':');
        if (colon == std::string::npos) return;
        NSString* scheme =
            [[NSString stringWithUTF8String:url.substr(0, colon).c_str()]
                lowercaseString];
        if (!SonrisaDeeplinkIsSchemeAllowed(scheme)) return;
        NSString* urlStr = [NSString stringWithUTF8String:url.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"SonrisaDeeplinkRequested"
                              object:urlStr];
        });
    }

private:
    const bool adblock_;
    IMPLEMENT_REFCOUNTING(SonrisaResourceHandler);
    DISALLOW_COPY_AND_ASSIGN(SonrisaResourceHandler);
};

}  // namespace

// MARK: - Download callback for favicons

class FaviconImageCallback : public CefDownloadImageCallback {
public:
    FaviconImageCallback(CEFBrowserController* controller,
                         CefRefPtr<CefBrowser> browser,
                         std::vector<CefString> remaining,
                         NSString* host)
        : controller_(controller),
          browser_(browser),
          remaining_(std::move(remaining)),
          host_([host copy]) {}

    void OnDownloadImageFinished(const CefString& image_url,
                                 int http_status_code,
                                 CefRefPtr<CefImage> image) override {
        CEFBrowserController* controller = controller_;
        if (!controller) {
            return;
        }
        if (image) {
            int width = 0, height = 0;
            CefRefPtr<CefBinaryValue> png =
                image->GetAsPNG(1.0f, true, width, height);
            if (png && png->GetSize() > 0) {
                const size_t size = png->GetSize();
                NSMutableData* data = [NSMutableData dataWithLength:size];
                png->GetData([data mutableBytes], size, 0);
                [controller cefFaviconData:data forHost:host_];
                return;
            }
        }
        // This URL failed to yield a usable image — fall through to the next
        // candidate (remaining declared icons, then /favicon.ico, then
        // /apple-touch-icon.png).
        if (!remaining_.empty() && browser_) {
            [controller cefTryFaviconURLs:remaining_ browser:browser_ host:host_];
        }
    }

private:
    __weak CEFBrowserController* controller_;
    CefRefPtr<CefBrowser> browser_;
    std::vector<CefString> remaining_;
    NSString* host_;
    IMPLEMENT_REFCOUNTING(FaviconImageCallback);
    DISALLOW_COPY_AND_ASSIGN(FaviconImageCallback);
};

// MARK: - Image fetch for "Copy Image"

// Fetches the image bytes through the frame's request context (cookies and
// auth apply) and puts the decoded bitmap on the general pasteboard.
class ImageCopyRequestClient : public CefURLRequestClient {
public:
    void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
        if (request->GetRequestStatus() != UR_SUCCESS || data_.empty()) return;
        NSData* bytes = [NSData dataWithBytes:data_.data() length:data_.size()];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImage* image = [[NSImage alloc] initWithData:bytes];
            if (!image) return;
            NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard writeObjects:@[ image ]];
        });
    }
    void OnUploadProgress(CefRefPtr<CefURLRequest> request,
                          int64_t current,
                          int64_t total) override {}
    void OnDownloadProgress(CefRefPtr<CefURLRequest> request,
                            int64_t current,
                            int64_t total) override {}
    void OnDownloadData(CefRefPtr<CefURLRequest> request,
                        const void* data,
                        size_t data_length) override {
        data_.append(static_cast<const char*>(data), data_length);
    }
    bool GetAuthCredentials(bool isProxy,
                            const CefString& host,
                            int port,
                            const CefString& realm,
                            const CefString& scheme,
                            CefRefPtr<CefAuthCallback> callback) override {
        return false;
    }

private:
    std::string data_;
    IMPLEMENT_REFCOUNTING(ImageCopyRequestClient);
};

// MARK: - CefClient implementation

class SonrisaCefClient : public CefClient,
                         public CefLifeSpanHandler,
                         public CefLoadHandler,
                         public CefDisplayHandler,
                         public CefFocusHandler,
                         public CefRequestHandler,
                         public CefDownloadHandler,
                         public CefPermissionHandler,
                         public CefContextMenuHandler {
public:
    explicit SonrisaCefClient(CEFBrowserController* controller)
        : controller_(controller),
          message_router_(
              CefMessageRouterBrowserSide::Create(CefMessageRouterConfig())),
          password_handler_(std::make_unique<PasswordQueryHandler>(controller)) {
        message_router_->AddHandler(password_handler_.get(), /*first=*/false);
    }

    ~SonrisaCefClient() override {
        // Cancels any queries still in flight (OnBeforeClose normally already
        // canceled the browser's queries; this covers teardown paths where it
        // never ran, e.g. a browser that failed to create).
        message_router_->RemoveHandler(password_handler_.get());
    }

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }

    // CefContextMenuHandler — Chrome's default items ("Open Link in New
    // Tab", "View Page Source", "Inspect") create native Chrome tabs and
    // windows that bypass Sonrisa's tab strip and DevTools placement.
    // Replace every non-editable menu with items routed through the app;
    // editable fields keep Chrome's cut/copy/paste/spellcheck menu.
    enum : int {
        kMenuOpenLinkInNewTab = MENU_ID_USER_FIRST,
        kMenuCopyLink,
        kMenuBack,
        kMenuForward,
        kMenuReload,
        kMenuPrint,
        kMenuCopy,
        kMenuOpenImageInNewTab,
        kMenuCopyImage,
        kMenuCopyImageURL,
        kMenuSaveImage,
        kMenuViewSource,
        kMenuInspectElement,
    };

    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override {
        // Capture now — |params| may not survive until the command callback.
        last_link_url_ = params->GetLinkUrl().ToString();
        last_source_url_ = params->GetSourceUrl().ToString();
        last_frame_url_ = frame ? frame->GetURL().ToString() : std::string();
        last_click_x_ = params->GetXCoord();
        last_click_y_ = params->GetYCoord();

        const auto flags = params->GetTypeFlags();
        if (flags & CM_TYPEFLAG_EDITABLE) {
            model->AddSeparator();
            model->AddItem(kMenuInspectElement, "Inspect Element");
            return;
        }

        const bool link = !params->GetLinkUrl().empty();
        const bool image = (flags & CM_TYPEFLAG_MEDIA) &&
                           params->GetMediaType() == CM_MEDIATYPE_IMAGE;
        const bool selection = (flags & CM_TYPEFLAG_SELECTION) != 0;

        model->Clear();
        if (link) {
            model->AddItem(kMenuOpenLinkInNewTab, "Open Link in New Tab");
            model->AddItem(kMenuCopyLink, "Copy Link");
            model->AddSeparator();
        }
        if (image) {
            model->AddItem(kMenuOpenImageInNewTab, "Open Image in New Tab");
            model->AddItem(kMenuCopyImage, "Copy Image");
            model->AddItem(kMenuCopyImageURL, "Copy Image Address");
            model->AddItem(kMenuSaveImage, "Save Image As…");
            model->AddSeparator();
        }
        if (selection) {
            model->AddItem(kMenuCopy, "Copy");
            model->AddSeparator();
        }
        if (!link && !image && !selection) {
            model->AddItem(kMenuBack, "Back");
            model->SetEnabled(kMenuBack, browser->CanGoBack());
            model->AddItem(kMenuForward, "Forward");
            model->SetEnabled(kMenuForward, browser->CanGoForward());
            model->AddItem(kMenuReload, "Reload");
            model->AddSeparator();
            model->AddItem(kMenuPrint, "Print…");
            model->AddSeparator();
        }
        model->AddItem(kMenuViewSource, (frame && !frame->IsMain())
                                            ? "View Frame Source"
                                            : "View Page Source");
        model->AddItem(kMenuInspectElement, "Inspect Element");
    }

    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params,
                              int command_id,
                              EventFlags event_flags) override {
        std::string linkStd = params->GetLinkUrl().ToString();
        if (linkStd.empty()) linkStd = last_link_url_;
        NSString* link = [NSString stringWithUTF8String:linkStd.c_str()];
        std::string srcStd = params->GetSourceUrl().ToString();
        if (srcStd.empty()) srcStd = last_source_url_;
        NSString* src = [NSString stringWithUTF8String:srcStd.c_str()];
        switch (command_id) {
            case kMenuOpenLinkInNewTab:
                if (link.length > 0) {
                    [controller_ cefPopupRequested:link];
                }
                return true;
            case kMenuCopyLink: {
                NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
                [pasteboard clearContents];
                [pasteboard setString:link forType:NSPasteboardTypeString];
                return true;
            }
            case kMenuBack:
                browser->GoBack();
                return true;
            case kMenuForward:
                browser->GoForward();
                return true;
            case kMenuReload:
                browser->Reload();
                return true;
            case kMenuPrint:
                browser->GetHost()->Print();
                return true;
            case kMenuCopy:
                if (frame) frame->Copy();
                return true;
            case kMenuOpenImageInNewTab:
                if (src.length > 0) {
                    [controller_ cefPopupRequested:src];
                }
                return true;
            case kMenuCopyImage: {
                if (srcStd.empty()) return true;
                if (srcStd.rfind("data:", 0) == 0) {
                    // data: URLs decode locally; no network fetch needed.
                    NSURL* dataURL = [NSURL URLWithString:src];
                    NSData* bytes =
                        dataURL ? [NSData dataWithContentsOfURL:dataURL] : nil;
                    NSImage* image =
                        bytes ? [[NSImage alloc] initWithData:bytes] : nil;
                    if (image) {
                        NSPasteboard* pasteboard =
                            [NSPasteboard generalPasteboard];
                        [pasteboard clearContents];
                        [pasteboard writeObjects:@[ image ]];
                    }
                    return true;
                }
                if (frame) {
                    CefRefPtr<CefRequest> request = CefRequest::Create();
                    request->SetURL(srcStd);
                    request->SetMethod("GET");
                    request->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS);
                    frame->CreateURLRequest(request,
                                            new ImageCopyRequestClient());
                }
                return true;
            }
            case kMenuCopyImageURL: {
                NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
                [pasteboard clearContents];
                [pasteboard setString:src forType:NSPasteboardTypeString];
                return true;
            }
            case kMenuSaveImage:
                if (!srcStd.empty()) {
                    next_download_shows_dialog_ = true;
                    browser->GetHost()->StartDownload(srcStd);
                }
                return true;
            case kMenuViewSource: {
                std::string pageUrl =
                    frame ? frame->GetURL().ToString() : std::string();
                if (pageUrl.empty()) pageUrl = last_frame_url_;
                if (!pageUrl.empty() &&
                    pageUrl.rfind("view-source:", 0) != 0) {
                    NSString* target = [NSString
                        stringWithUTF8String:("view-source:" + pageUrl).c_str()];
                    [controller_ cefPopupRequested:target];
                }
                return true;
            }
            case kMenuInspectElement: {
                int x = params->GetXCoord();
                int y = params->GetYCoord();
                if (x < 0 || y < 0) {
                    x = last_click_x_;
                    y = last_click_y_;
                }
                [controller_ cefInspectElementRequestedAtX:x y:y];
                return true;
            }
            default:
                return false;
        }
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        return message_router_->OnProcessMessageReceived(browser, frame,
                                                         source_process, message);
    }

    // CefRequestHandler (message router bookkeeping)
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override {
        message_router_->OnBeforeBrowse(browser, frame);
        if (frame && frame->IsMain()) {
            CefURLParts targetParts, currentParts;
            std::string targetScheme, targetHost, currentHost;
            if (CefParseURL(request->GetURL(), targetParts)) {
                targetScheme = CefString(&targetParts.scheme).ToString();
                targetHost = CefString(&targetParts.host).ToString();
            }
            if (CefParseURL(frame->GetURL(), currentParts)) {
                currentHost = CefString(&currentParts.host).ToString();
            }
            // Deeplink scheme in the main frame (spotify:, zoommtg:, …):
            // cancel the navigation so Chrome's ERR_UNKNOWN_URL_SCHEME error
            // page never renders, and let the Swift side prompt instead.
            static const std::unordered_set<std::string> kWebSchemes = {
                "http", "https", "file", "about", "chrome", "view-source",
                "devtools", "data", "blob", "javascript", "ws", "wss",
                "chrome-extension",
            };
            if (!targetScheme.empty() && !kWebSchemes.count(targetScheme)) {
                NSString* schemeNS =
                    [NSString stringWithUTF8String:targetScheme.c_str()];
                if (SonrisaDeeplinkIsSchemeAllowed(schemeNS)) {
                    NSString* urlStr = [NSString
                        stringWithUTF8String:request->GetURL()
                                                 .ToString()
                                                 .c_str()];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"SonrisaDeeplinkRequested"
                                          object:urlStr];
                    });
                }
                return true;
            }
            // Entering a site from another host may match an app's web
            // domain (open.spotify.com, apps.apple.com, …) — the Swift side
            // prompts "Open in <app>?" while the page loads normally. Only
            // cross-host entries, so clicks within the site don't re-prompt.
            if ((targetScheme == "http" || targetScheme == "https") &&
                !targetHost.empty() && targetHost != currentHost) {
                NSString* urlStr = [NSString
                    stringWithUTF8String:request->GetURL().ToString().c_str()];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"SonrisaAppLinkRequested"
                                      object:urlStr];
                });
            }
        }
        return false;
    }


    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status,
                                   int error_code,
                                   const CefString& error_string) override {
        message_router_->OnRenderProcessTerminated(browser);
        [controller_ cefRenderProcessCrashed];
    }

    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        bool is_navigation,
        bool is_download,
        const CefString& request_initiator,
        bool& disable_default_handling) override {
        // Adblock cancels subresources only — cancelling top-level
        // navigations would break redirect chains through blocklisted link
        // routers. The handler is returned for every request so
        // OnProtocolExecution can route enabled deeplink schemes to the OS.
        bool adblock =
            !is_navigation && gAdblockEnabled.load(std::memory_order_relaxed) &&
            adblock_enabled_.load(std::memory_order_relaxed);
        return new SonrisaResourceHandler(adblock);
    }

    // Per-browser override; read on the IO thread, written from main.
    void SetAdblockEnabled(bool enabled) { adblock_enabled_.store(enabled); }

    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                            const CefString& origin_url,
                            bool isProxy,
                            const CefString& host,
                            int port,
                            const CefString& realm,
                            const CefString& scheme,
                            CefRefPtr<CefAuthCallback> callback) override {
        // Called on the IO thread; the controller hops to main for the UI.
        CefRefPtr<CefAuthCallback> cb = callback;
        return [controller_ cefAuthRequestHost:ToNSString(host)
                                          port:port
                                         realm:ToNSString(realm)
                                    completion:^(NSString* user, NSString* pass) {
            if (user) {
                CefString u, p;
                u.FromString([user UTF8String]);
                p.FromString([(pass ?: @"") UTF8String]);
                cb->Continue(u, p);
            } else {
                cb->Cancel();
            }
        }];
    }

    // CefPermissionHandler — surface capability requests as app dialogs.
    static NSString* PermissionNames(uint32_t mask) {
        NSMutableArray* parts = [NSMutableArray array];
        if (mask & CEF_PERMISSION_TYPE_CAMERA_STREAM) [parts addObject:@"camera"];
        if (mask & CEF_PERMISSION_TYPE_MIC_STREAM) [parts addObject:@"microphone"];
        if (mask & CEF_PERMISSION_TYPE_GEOLOCATION) [parts addObject:@"location"];
        if (mask & CEF_PERMISSION_TYPE_NOTIFICATIONS) [parts addObject:@"notifications"];
        if (mask & CEF_PERMISSION_TYPE_CLIPBOARD) [parts addObject:@"clipboard"];
        if (parts.count == 0) [parts addObject:@"additional capabilities"];
        return [parts componentsJoinedByString:@", "];
    }

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString& requesting_origin,
                                        uint32_t requested_permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        NSMutableArray* parts = [NSMutableArray array];
        if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE)
            [parts addObject:@"camera"];
        if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)
            [parts addObject:@"microphone"];
        if ((requested_permissions & CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) ||
            (requested_permissions & CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE))
            [parts addObject:@"screen sharing"];
        if (parts.count == 0) [parts addObject:@"media access"];
        const uint32_t perms = requested_permissions;
        CefRefPtr<CefMediaAccessCallback> cb = callback;
        [controller_ cefPermissionPromptOrigin:ToNSString(requesting_origin)
                                   permissions:[parts componentsJoinedByString:@", "]
                                    completion:^(BOOL allow) {
            if (allow) cb->Continue(perms); else cb->Cancel();
        }];
        return true;
    }

    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                uint64_t prompt_id,
                                const CefString& requesting_origin,
                                uint32_t requested_permissions,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        CefRefPtr<CefPermissionPromptCallback> cb = callback;
        [controller_ cefPermissionPromptOrigin:ToNSString(requesting_origin)
                                   permissions:PermissionNames(requested_permissions)
                                    completion:^(BOOL allow) {
            cb->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT
                               : CEF_PERMISSION_RESULT_DENY);
        }];
        return true;
    }

    // CefDownloadHandler — save to ~/Downloads under a unique name.
    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        NSString* dir = [NSSearchPathForDirectoriesInDomains(
            NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
        NSString* name = ToNSString(suggested_name);
        if (name.length == 0) name = @"download";
        NSString* path = [dir stringByAppendingPathComponent:name];
        // "Save As…" flows show the native save panel (pre-filled with the
        // suggested path; the panel handles overwrite confirmation itself).
        if (next_download_shows_dialog_) {
            next_download_shows_dialog_ = false;
            CefString cefPath;
            cefPath.FromString([path UTF8String]);
            callback->Continue(cefPath, /*show_dialog=*/true);
            return true;
        }
        NSString* base = [name stringByDeletingPathExtension];
        NSString* ext = [name pathExtension];
        NSFileManager* fm = [NSFileManager defaultManager];
        for (int n = 2; [fm fileExistsAtPath:path]; n++) {
            NSString* candidate = ext.length
                ? [NSString stringWithFormat:@"%@ (%d).%@", base, n, ext]
                : [NSString stringWithFormat:@"%@ (%d)", base, n];
            path = [dir stringByAppendingPathComponent:candidate];
        }
        // Never start automatically — ask first. Declining marks the id so
        // the next OnDownloadUpdated cancels it.
        NSView* view =
            (__bridge NSView*)browser->GetHost()->GetWindowHandle();
        NSWindow* window = view.window ?: NSApp.keyWindow;
        std::string pathStd = [path UTF8String];
        CefRefPtr<CefBeforeDownloadCallback> cb = callback;
        if (!window) {
            CefString cefPath;
            cefPath.FromString(pathStd);
            cb->Continue(cefPath, /*show_dialog=*/false);
            return true;
        }
        uint32_t downloadId = download_item->GetId();
        NSMutableIndexSet* declined = declined_downloads_;
        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText =
            [NSString stringWithFormat:@"Download “%@”?", name];
        alert.informativeText = @"It will be saved to your Downloads folder.";
        [alert addButtonWithTitle:@"Download"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:window
                      completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                CefString cefPath;
                cefPath.FromString(pathStd);
                cb->Continue(cefPath, /*show_dialog=*/false);
            } else {
                [declined addIndex:downloadId];
            }
        }];
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        uint32_t downloadId = download_item->GetId();
        if ([declined_downloads_ containsIndex:downloadId]) {
            [declined_downloads_ removeIndex:downloadId];
            callback->Cancel();
            return;
        }
        [controller_ cefDownloadUpdate:download_item->GetId()
                                  path:ToNSString(download_item->GetFullPath())
                              received:download_item->GetReceivedBytes()
                                 total:download_item->GetTotalBytes()
                              complete:download_item->IsComplete()
                              canceled:(download_item->IsCanceled() ||
                                        download_item->IsInterrupted())];
    }

    // CefFocusHandler
    bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
        // Browser creation and page loads must not steal focus from the app
        // chrome (e.g. the address bar of a fresh tab). Returning true cancels
        // the focus grab; user-initiated focus (clicking the page) still works.
        return source == FOCUS_SOURCE_NAVIGATION;
    }

    // CefLifeSpanHandler
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        RegistryAddBrowser(browser);
        [controller_ cefAttachBrowser:browser];
    }

    // Teardown has reached the point where CEF waits for the browser view's
    // top-level window (the scratch window) to close. Close it now — closing
    // it any earlier doesn't count and the browser leaks alive (still playing
    // audio) with OnBeforeClose never firing.
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        NSView* view =
            (__bridge NSView*)browser->GetHost()->GetWindowHandle();
        NSWindow* window = view.window;
        if (window && (window == [controller_ cefScratchCloseWindow] ||
                       [gQuitScratchWindows containsObject:window])) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [view removeFromSuperview];
                [window close];
            });
            return false;  // proceed with default close handling
        }
        // Close initiated by the page itself (JS window.close()) arrives here
        // with the view still in the real app window. CEF's default handling
        // performCloses the view's top-level window — the whole app window.
        // Cancel it and close just the owning tab through the normal
        // scratch-window path instead.
        if (window) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [controller_ cefPageRequestedClose];
            });
            return true;
        }
        return false;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        message_router_->OnBeforeClose(browser);
        [controller_ cefDetachBrowser];
        // Last: may fire the all-closed callback that finishes app shutdown.
        RegistryRemoveBrowser(browser);
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        // Suppress the native Chrome popup window; the app opens the URL in a
        // regular Sonrisa tab instead.
        if (!target_url.empty()) {
            [controller_ cefPopupRequested:ToNSString(target_url)];
        }
        return true;
    }

    // CefLoadHandler
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading,
                              bool canGoBack,
                              bool canGoForward) override {
        [controller_ cefLoadingChanged:isLoading
                                  back:canGoBack
                               forward:canGoForward];
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode errorCode,
                     const CefString& errorText,
                     const CefString& failedUrl) override {
        NSLog(@"[Sonrisa] OnLoadError code=%d text=%@ url=%@", errorCode,
              ToNSString(errorText), ToNSString(failedUrl));
    }

    // CefDisplayHandler
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override {
        [controller_ cefTitleChanged:ToNSString(title)];
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (frame && frame->IsMain()) {
            [controller_ cefURLChanged:ToNSString(url)];
        }
    }

    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                bool fullscreen) override {
        [controller_ cefFullscreenModeChanged:fullscreen];
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                            const std::vector<CefString>& icon_urls) override {
        // Build an ordered candidate list: declared icons (SVG last — CEF's
        // image decoder can't rasterize them reliably), then well-known
        // origin fallbacks. Each candidate is tried until one decodes.
        std::vector<CefString> ordered;
        std::vector<CefString> svgs;
        for (const auto& url : icon_urls) {
            std::string s = url.ToString();
            std::string lower(s);
            std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
            size_t query = lower.find_first_of("?#");
            std::string path = lower.substr(0, query);
            if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".svg") == 0) {
                svgs.push_back(url);
            } else {
                ordered.push_back(url);
            }
        }
        ordered.insert(ordered.end(), svgs.begin(), svgs.end());

        // Origin-based fallbacks in case every declared icon is dead.
        if (CefRefPtr<CefFrame> main_frame = browser->GetMainFrame()) {
            std::string url = main_frame->GetURL().ToString();
            size_t scheme_end = url.find("://");
            if (scheme_end != std::string::npos &&
                (url.compare(0, scheme_end, "http") == 0 ||
                 url.compare(0, scheme_end, "https") == 0)) {
                size_t path_start = url.find('/', scheme_end + 3);
                std::string origin = url.substr(0, path_start);
                ordered.push_back(origin + "/favicon.ico");
                ordered.push_back(origin + "/apple-touch-icon.png");
            }
        }
        if (!ordered.empty()) {
            [controller_ cefRequestFaviconDownload:browser urls:ordered];
        }
    }

private:
    __weak CEFBrowserController* controller_;
    CefRefPtr<CefMessageRouterBrowserSide> message_router_;
    std::unique_ptr<PasswordQueryHandler> password_handler_;
    std::atomic<bool> adblock_enabled_{true};
    std::string last_link_url_;
    std::string last_source_url_;
    // Set by "Save Image As…" so the next download shows a save panel
    // instead of silently landing in ~/Downloads.
    bool next_download_shows_dialog_ = false;
    // Download ids declined in the ask-first sheet; canceled on the next
    // OnDownloadUpdated tick (CefBeforeDownloadCallback has no cancel).
    NSMutableIndexSet* declined_downloads_ = [NSMutableIndexSet indexSet];
    std::string last_frame_url_;
    int last_click_x_ = 0;
    int last_click_y_ = 0;
    IMPLEMENT_REFCOUNTING(SonrisaCefClient);
    DISALLOW_COPY_AND_ASSIGN(SonrisaCefClient);
};

}  // namespace

// MARK: - Adblock C API (global linkage — declared in the header)

void SonrisaAdblockLoadHostsFile(NSString* path) {
    auto hosts = std::make_shared<std::unordered_set<std::string>>();
    std::ifstream file([path UTF8String]);
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '#') continue;
        // hosts format: "0.0.0.0 domain" — take the last token; bare-domain
        // lists just have the domain.
        size_t space = line.find_last_of(" \t");
        std::string host = space == std::string::npos ? line : line.substr(space + 1);
        while (!host.empty() && (host.back() == '\r' || host.back() == ' ')) {
            host.pop_back();
        }
        if (host.empty() || host == "localhost" || host == "0.0.0.0" ||
            host == "broadcasthost" || host.find('.') == std::string::npos) {
            continue;
        }
        std::transform(host.begin(), host.end(), host.begin(), ::tolower);
        hosts->insert(std::move(host));
    }
    std::lock_guard<std::mutex> lock(gAdblockMutex);
    gAdblockHosts = std::move(hosts);
}

void SonrisaAdblockSetEnabled(BOOL enabled) {
    gAdblockEnabled.store(enabled);
}

BOOL SonrisaAdblockIsEnabled(void) {
    return gAdblockEnabled.load();
}

NSUInteger SonrisaAdblockHostCount(void) {
    std::lock_guard<std::mutex> lock(gAdblockMutex);
    return gAdblockHosts->size();
}

NSUInteger SonrisaAdblockBlockedCount(void) {
    return (NSUInteger)gAdblockBlocked.load(std::memory_order_relaxed);
}

// MARK: - Deeplink schemes

// Written from Swift on the main thread; read in OnProtocolExecution, which
// can run on the IO thread — hence the mutex.
static std::mutex gDeeplinkMutex;
static NSSet<NSString*>* gDeeplinkSchemes = nil;

void SonrisaDeeplinkSetAllowedSchemes(NSArray<NSString*>* schemes) {
    NSMutableSet* set = [NSMutableSet set];
    for (NSString* scheme in schemes) {
        [set addObject:scheme.lowercaseString];
    }
    std::lock_guard<std::mutex> lock(gDeeplinkMutex);
    gDeeplinkSchemes = set;
}

BOOL SonrisaDeeplinkIsSchemeAllowed(NSString* scheme) {
    if (scheme == nil) return NO;
    std::lock_guard<std::mutex> lock(gDeeplinkMutex);
    return [gDeeplinkSchemes containsObject:scheme];
}

// MARK: - Incognito request context

/// All incognito browsers share one off-the-record context. Empty cache_path
/// keeps cookies/cache/storage purely in memory; it disappears on quit.
// Defined in CEFRuntime.mm; kills Chrome's native autofill/password popups
// (the app draws its own — both would show on the same input).
void SonrisaDisableNativeAutofill(CefRefPtr<CefRequestContext> context);

static CefRefPtr<CefRequestContext> IncognitoRequestContext() {
    static CefRefPtr<CefRequestContext>* context =
        new CefRefPtr<CefRequestContext>;
    if (!*context) {
        CefRequestContextSettings settings;
        *context = CefRequestContext::CreateContext(settings, nullptr);
        SonrisaDisableNativeAutofill(*context);
    }
    return *context;
}

// MARK: - Obj-C controller

@implementation CEFBrowserController {
    NSView* _containerView;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<SonrisaCefClient> _client;
    NSString* _pendingURL;
    NSString* _currentHost;
    // Keeps the controller (and its CEF-parented NSView) alive across the
    // asynchronous CloseBrowser() until OnBeforeClose fires. Without this the
    // Swift Tab can drop its last strong ref before CEF finishes teardown,
    // freeing the browser host + view mid-close (use-after-free crash).
    CEFBrowserController* _selfDuringClose;
    // Close arrived before the async CreateBrowser finished; close on attach.
    BOOL _closeRequested;
    // Offscreen window the CEF view is reparented into for the duration of a
    // close. CloseBrowser on a child-view browser sends performClose: to the
    // view's TOP-LEVEL window — left in place, that closes the app window
    // (AppKit then auto-terminates via terminate-after-last-window-closed).
    NSWindow* _scratchCloseWindow;
    // Per-browser DevTools protocol channel used to resolve the CDP target id
    // for the docked-DevTools frontend.
    CefRefPtr<CefDevToolsMessageObserver> _devtoolsObserver;
    CefRefPtr<CefRegistration> _devtoolsRegistration;
    int _devtoolsMessageID;
    NSMutableDictionary<NSNumber*, void (^)(NSString* _Nullable)>* _devtoolsCompletions;
}

/// Receives ExecuteDevToolsMethod results; extracts Target.getTargetInfo's
/// targetId. Runs on the UI (main) thread.
namespace {
class SonrisaDevToolsObserver : public CefDevToolsMessageObserver {
public:
    explicit SonrisaDevToolsObserver(CEFBrowserController* controller)
        : controller_(controller) {}

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                                int message_id,
                                bool success,
                                const void* result,
                                size_t result_size) override {
        NSString* targetID = nil;
        if (success && result && result_size > 0) {
            NSData* data = [NSData dataWithBytes:result length:result_size];
            id json = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0
                                                        error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                id info = json[@"targetInfo"];
                if ([info isKindOfClass:NSDictionary.class]) {
                    id tid = info[@"targetId"];
                    if ([tid isKindOfClass:NSString.class]) {
                        targetID = tid;
                    }
                }
            }
        }
        [controller_ cefDevToolsResult:message_id targetID:targetID];
    }

private:
    CEFBrowserController* controller_;
    IMPLEMENT_REFCOUNTING(SonrisaDevToolsObserver);
};
}  // namespace

/// Moves the browser's NSView into a hidden closable window so CEF's
/// close-the-top-level-window behavior hits the scratch window, not the app's.
static NSWindow* DetachIntoScratchWindow(CefRefPtr<CefBrowser> browser) {
    NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (!cefView) {
        return nil;
    }
    NSWindow* scratch =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(-16000, -16000, 4, 4)
                                    styleMask:(NSWindowStyleMaskTitled |
                                               NSWindowStyleMaskClosable)
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    scratch.releasedWhenClosed = NO;  // ARC owns it
    scratch.alphaValue = 0.0;         // belt-and-suspenders: fully offscreen anyway
    scratch.excludedFromWindowsMenu = YES;
    [cefView removeFromSuperview];
    [scratch.contentView addSubview:cefView];
    // CEF only finishes destroying a windowed browser once its OS window
    // actually goes through a real close (OnBeforeClose never fires otherwise —
    // browsers pile up until CefShutdown). The window must exist for real
    // (ordered in, has a window number) for that close to count; a deferred
    // never-shown window doesn't. Do NOT close it here: teardown reaches
    // DoClose asynchronously (after the renderer unload roundtrip), and a
    // window closed before that point doesn't count — CEF waits forever for
    // a close notification that already happened. DoClose closes it instead.
    [scratch orderBack:nil];
    return scratch;
}

- (instancetype)initWithURL:(NSString *)url {
    return [self initWithURL:url incognito:NO];
}

- (instancetype)initWithURL:(NSString *)url incognito:(BOOL)incognito {
    self = [super init];
    if (self) {
        _incognito = incognito;
        _adblockEnabled = YES;
        _pendingURL = [url copy];
        _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        _containerView.autoresizesSubviews = YES;
        _containerView.wantsLayer = YES;
        [self createBrowser];
    }
    return self;
}

- (NSView *)containerView {
    return _containerView;
}

- (void)createBrowser {
    // CreateBrowser before OnContextInitialized crashes intermittently inside
    // CEF (Chrome runtime finishes startup async after CefInitialize returns).
    // Defer until the context is ready; navigation/state calls already tolerate
    // a nil _browser via _pendingURL.
    __weak __typeof(self) weakSelf = self;
    SonrisaRunWhenCefContextInitialized(^{
        [weakSelf createBrowserNow];
    });
}

- (void)setAdblockEnabled:(BOOL)adblockEnabled {
    _adblockEnabled = adblockEnabled;
    if (_client) {
        _client->SetAdblockEnabled(adblockEnabled);
    }
}

- (void)createBrowserNow {
    _client = new SonrisaCefClient(self);
    _client->SetAdblockEnabled(_adblockEnabled);

    CefWindowInfo window_info;
    const NSRect bounds = _containerView.bounds;
    window_info.SetAsChild((__bridge void*)_containerView,
                           CefRect(0, 0, (int)bounds.size.width,
                                   (int)bounds.size.height));
    // Chrome runtime style (default). Chrome closes the top-level window that
    // hosts a browser when the browser closes — DetachIntoScratchWindow gives
    // it a sacrificial window so the app window is never the target.

    CefBrowserSettings browser_settings;

    CefString cefURL;
    cefURL.FromString([(_pendingURL ?: @"about:blank") UTF8String]);

    CefBrowserHost::CreateBrowser(window_info, _client.get(), cefURL,
                                  browser_settings, nullptr,
                                  _incognito ? IncognitoRequestContext()
                                             : nullptr);
}

// MARK: Navigation

- (void)loadURL:(NSString *)url {
    if (_browser) {
        CefString cefURL;
        cefURL.FromString([url UTF8String]);
        _browser->GetMainFrame()->LoadURL(cefURL);
    } else {
        _pendingURL = [url copy];
    }
}

- (void)goBack {
    if (_browser) _browser->GoBack();
}

- (void)goForward {
    if (_browser) _browser->GoForward();
}

- (void)reload {
    if (_browser) _browser->Reload();
}

- (void)stopLoad {
    if (_browser) _browser->StopLoad();
}

- (void)close {
    // Either way, keep self (and _containerView, which CEF parents its child
    // view into) alive until OnBeforeClose; released in cefDetachBrowser.
    _selfDuringClose = self;
    if (_browser) {
        _scratchCloseWindow = DetachIntoScratchWindow(_browser);
        _browser->GetHost()->CloseBrowser(true);
    } else {
        // CefBrowserHost::CreateBrowser is asynchronous — the tab was closed
        // before OnAfterCreated fired (fresh tab, nothing visited yet). Freeing
        // the controller now would hand CEF a dead parent view mid-creation.
        // Latch instead; cefAttachBrowser closes the browser as soon as it
        // exists, and OnBeforeClose then releases the self-ref as usual.
        _closeRequested = YES;
    }
}

// MARK: Callbacks from the C++ layer (already on the main thread)

- (void)cefAttachBrowser:(CefRefPtr<CefBrowser>)browser {
    if (_closeRequested) {
        // Tab was closed while creation was in flight; discard immediately.
        _scratchCloseWindow = DetachIntoScratchWindow(browser);
        browser->GetHost()->CloseBrowser(true);
        return;
    }
    _browser = browser;
    NSView* cefView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    cefView.frame = _containerView.bounds;
    cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)cefDetachBrowser {
    _browser = nullptr;
    // Release the self-ref on a later runloop turn, NOT synchronously: this is
    // called from inside SonrisaCefClient::OnBeforeClose, and dealloc would
    // release _client (the CefRefPtr to that very client) mid-callback -> UAF.
    dispatch_async(dispatch_get_main_queue(), ^{
        _scratchCloseWindow = nil;
        _selfDuringClose = nil;
    });
}

- (void)cefTitleChanged:(NSString *)title {
    if (self.onTitleChanged) self.onTitleChanged(title);
}

- (void)cefURLChanged:(NSString *)url {
    _currentHost = [[NSURLComponents componentsWithString:url] host] ?: url;
    if (self.onURLChanged) self.onURLChanged(url);
}

- (void)cefLoadingChanged:(BOOL)loading back:(BOOL)canBack forward:(BOOL)canForward {
    if (self.onLoadingStateChanged) self.onLoadingStateChanged(loading, canBack, canForward);
}

- (void)cefRequestFaviconDownload:(CefRefPtr<CefBrowser>)browser
                             urls:(const std::vector<CefString> &)iconURLs {
    // Capture the host now — by the time downloads finish the browser may
    // have navigated elsewhere, and the icon must be stored under the host
    // it belongs to.
    [self cefTryFaviconURLs:iconURLs browser:browser host:_currentHost];
}

- (void)cefTryFaviconURLs:(const std::vector<CefString> &)urls
                  browser:(CefRefPtr<CefBrowser>)browser
                     host:(NSString *)host {
    if (urls.empty() || !browser || host.length == 0) return;
    std::vector<CefString> rest(urls.begin() + 1, urls.end());
    CefRefPtr<FaviconImageCallback> callback =
        new FaviconImageCallback(self, browser, std::move(rest), host);
    browser->GetHost()->DownloadImage(urls.front(), /*is_favicon=*/true,
                                      /*max_image_size=*/64,
                                      /*bypass_cache=*/false, callback);
}

- (void)cefFaviconData:(NSData *)png forHost:(NSString *)host {
    if (self.onFaviconReady && host.length > 0) {
        self.onFaviconReady(host, png);
    }
}

- (void)cefPopupRequested:(NSString *)url {
    if (self.onPopupRequested) {
        self.onPopupRequested(url);
    }
}

- (void)cefPageRequestedClose {
    if (self.onPageRequestedClose) {
        self.onPageRequestedClose();
    } else {
        // No owner wired up (shouldn't happen for real tabs) — close the
        // browser through the scratch-window path so the app window survives.
        [self close];
    }
}

- (void)cefInspectElementRequestedAtX:(int)x y:(int)y {
    if (self.onInspectElementRequested) {
        self.onInspectElementRequested(x, y);
    }
}

- (NSWindow *)cefScratchCloseWindow {
    return _scratchCloseWindow;
}

// MARK: Find / zoom / print

- (void)findInPage:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext {
    if (!_browser || text.length == 0) return;
    CefString cefText;
    cefText.FromString([text UTF8String]);
    _browser->GetHost()->Find(cefText, forward, /*matchCase=*/false, findNext);
}

- (void)stopFinding {
    if (!_browser) return;
    _browser->GetHost()->StopFinding(/*clearSelection=*/true);
}

- (void)zoomBy:(double)delta {
    if (!_browser) return;
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    host->SetZoomLevel(host->GetZoomLevel() + delta);
}

- (void)zoomReset {
    if (!_browser) return;
    _browser->GetHost()->SetZoomLevel(0.0);
}

- (void)printPage {
    if (!_browser) return;
    _browser->GetHost()->Print();
}

- (void)showDevToolsInWindow {
    if (!_browser) return;
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (host->HasDevTools()) {
        host->CloseDevTools();
    }
    // Default window info: DevTools opens in its own native window. Chrome-
    // style CEF CHECK-crashes on SetAsChild window info or a non-empty
    // inspect point — only this default-window form is safe.
    CefWindowInfo window_info;
    CefBrowserSettings settings;
    host->ShowDevTools(window_info, nullptr, settings, CefPoint());
}

- (void)fetchDevToolsTargetID:(void (^)(NSString *_Nullable))completion {
    if (!_browser) {
        completion(nil);
        return;
    }
    // One observer registration per controller; each fetch remembers its
    // message id and resolves the matching pending completion.
    if (!_devtoolsObserver) {
        _devtoolsObserver = new SonrisaDevToolsObserver(self);
        _devtoolsRegistration =
            _browser->GetHost()->AddDevToolsMessageObserver(_devtoolsObserver);
    }
    const int messageID = ++_devtoolsMessageID;
    if (!_devtoolsCompletions) _devtoolsCompletions = [NSMutableDictionary new];
    _devtoolsCompletions[@(messageID)] = [completion copy];
    _browser->GetHost()->ExecuteDevToolsMethod(messageID, "Target.getTargetInfo",
                                               nullptr);
}

- (void)evaluateViaDevToolsProtocol:(NSString *)javaScript {
    if (!_browser) return;
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    CefString expression;
    expression.FromString([javaScript UTF8String]);
    params->SetString("expression", expression);
    _browser->GetHost()->ExecuteDevToolsMethod(++_devtoolsMessageID,
                                               "Runtime.evaluate", params);
}

- (void)cefDevToolsResult:(int)messageID targetID:(NSString *_Nullable)targetID {
    void (^completion)(NSString *_Nullable) = _devtoolsCompletions[@(messageID)];
    if (!completion) return;
    [_devtoolsCompletions removeObjectForKey:@(messageID)];
    completion(targetID);
}

- (void)closeDevTools {
    if (_browser) _browser->GetHost()->CloseDevTools();
}

- (BOOL)hasDevTools {
    return _browser ? _browser->GetHost()->HasDevTools() : NO;
}

- (void)reloadIgnoringCache {
    if (_browser) _browser->ReloadIgnoreCache();
}

- (BOOL)isAudioMuted {
    return _browser ? _browser->GetHost()->IsAudioMuted() : NO;
}

- (void)setAudioMuted:(BOOL)muted {
    if (_browser) _browser->GetHost()->SetAudioMuted(muted);
}

- (void)cefRenderProcessCrashed {
    if (self.onRenderProcessCrashed) {
        self.onRenderProcessCrashed();
    }
}

- (void)cefFullscreenModeChanged:(BOOL)fullscreen {
    if (self.onFullscreenModeChanged) {
        self.onFullscreenModeChanged(fullscreen);
    }
}

// MARK: Downloads / auth bridging

- (void)cefDownloadUpdate:(uint32_t)downloadID
                     path:(NSString *)path
                 received:(int64_t)received
                    total:(int64_t)total
                 complete:(BOOL)complete
                 canceled:(BOOL)canceled {
    if (self.onDownloadUpdated) {
        self.onDownloadUpdated(downloadID, path, received, total, complete, canceled);
    }
}

- (void)cefPermissionPromptOrigin:(NSString *)origin
                      permissions:(NSString *)permissions
                       completion:(void (^)(BOOL))completion {
    void (^handler)(NSString *, NSString *, void (^)(BOOL)) = self.onPermissionRequested;
    if (!handler) {
        completion(NO);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(origin, permissions, completion);
    });
}

- (BOOL)cefAuthRequestHost:(NSString *)host
                      port:(int)port
                     realm:(NSString *)realm
                completion:(void (^)(NSString *, NSString *))completion {
    void (^handler)(NSString *, int, NSString *, void (^)(NSString *, NSString *)) =
        self.onAuthRequested;
    if (!handler) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(host, port, realm, completion);
    });
    return YES;
}

@end
