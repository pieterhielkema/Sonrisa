# Token discipline (read first)

Context re-bills every turn. Keep tool output and pastes tiny.

- Never read whole crash/log files. Extract the faulting thread: `scripts/crashthread.sh <file.ips>`. Never paste a full `.ips`.
- Cap every command's output: `| tail -30`, `| head -c 1500`, `| cut -c1-200`. Never dump full `pgrep -fl`, `defaults`, keychain, or build logs.
- Read file ranges/symbols, not whole files (`pbxproj`, `.mm` are large).
- Delegate exploration ("where is X", "map dir", crash triage) to a subagent so big reads stay out of main context.
- One task per session; `/clear` between tasks.

# Build / run

- App: `xcodebuild -project Sonrisa.xcodeproj -scheme Sonrisa -configuration Debug build` (pipe `| tail -4`).
- CEF helper is built separately by `scripts/embed_cef.sh <app>` — Xcode skips it when only `helper/helper_main.mm` changed, so run it manually after helper edits.
- Bundle id: `nl.pieterhielkema.Sonrisa`.

# Architecture (one-liners)

- CEF wrapped per-tab in `Sonrisa/CEF/CEFBrowserController.mm`; runtime + external message pump in `CEFRuntime.mm`.
- Pump caveat: `CefDoMessageLoopWork()` must not run re-entrantly — guarded by `gPumping`/`gShuttingDown`. Don't call it raw.
- Renderer subprocess entry: `helper/helper_main.mm` (message router lives here too).
