//
//  helper_main.mm
//  Sonrisa Helper
//
//  Entry point for CEF sub-processes (renderer, GPU, utility, ...). This tiny
//  executable is launched by CEF; it must not create any UI.
//
//  NOTE: This file lives outside the Sonrisa/ synchronized folder on purpose —
//  it defines main() and must not be compiled into the app target. It is built
//  by scripts/embed_cef.sh.
//

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_message_router.h"

#include "../Sonrisa/CEF/AutofillScript.h"
#include "../Sonrisa/CEF/JSONViewerScript.h"

namespace {

// Renderer-side half of the cefQuery message router. Exposes
// window.cefQuery()/cefQueryCancel() to page JavaScript so the injected
// password-autofill script can talk to the browser process. Also injects the
// autofill script at load end — injection must happen here in the renderer;
// browser-process ExecuteJavaScript is a silent no-op under the chrome-style
// runtime.
class HelperApp : public CefApp,
                  public CefRenderProcessHandler,
                  public CefLoadHandler {
public:
    HelperApp() = default;

    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
        return this;
    }

    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   int httpStatusCode) override {
        // Every frame gets the script; the browser process re-validates the
        // frame's real host before serving or saving any credentials.
        if (frame) {
            frame->ExecuteJavaScript(kSonrisaAutofillScript, frame->GetURL(), 0);
            // JSON viewer: main frame only; the script itself bails unless the
            // document is a JSON content type that parses.
            if (frame->IsMain()) {
                frame->ExecuteJavaScript(kSonrisaJSONViewerScript,
                                         frame->GetURL(), 0);
            }
        }
    }

    void OnWebKitInitialized() override {
        message_router_ =
            CefMessageRouterRendererSide::Create(CefMessageRouterConfig());
    }

    void OnContextCreated(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        if (message_router_) {
            message_router_->OnContextCreated(browser, frame, context);
        }
    }

    void OnContextReleased(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefV8Context> context) override {
        if (message_router_) {
            message_router_->OnContextReleased(browser, frame, context);
        }
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (message_router_ &&
            message_router_->OnProcessMessageReceived(browser, frame,
                                                      source_process, message)) {
            return true;
        }
        return false;
    }

private:
    CefRefPtr<CefMessageRouterRendererSide> message_router_;

    IMPLEMENT_REFCOUNTING(HelperApp);
    DISALLOW_COPY_AND_ASSIGN(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
    // Load the CEF framework from the outer app bundle's Frameworks directory
    // (../../.. relative to this helper executable).
    CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInHelper()) {
        return 1;
    }

    CefMainArgs main_args(argc, argv);
    CefRefPtr<HelperApp> app = new HelperApp();

    // Execute the sub-process logic. Blocks until the sub-process exits.
    return CefExecuteProcess(main_args, app.get(), nullptr);
}
