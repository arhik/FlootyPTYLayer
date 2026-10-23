# browserWindow.jl — a REAL browser window for BrowserSession.
#
# The in-app panel is an <iframe>. Many sites (GitHub, Google, most auth
# flows) send X-Frame-Options/CSP frame-ancestors and therefore refuse to
# render inside it — the panel stays blank no matter what. A BrowserSession
# now also gets a native WKWebView window, which is a top-level browser: it
# opens github.com, etc. The page keeps the URL bar/chat; the native window is
# the actual viewport.
#
# Webviews' public constructor calls on_application_did_finish_launching, which
# STOPS the NSApplication when parent_window == C_NULL. A second top-level
# Webview would therefore kill the app's run loop (measured). We first create
# an NSWindow ourselves and pass its handle as `unsafe_window_handle`, so the
# backend skips stop:, fills that window with a WKWebView, and shows it.

const BROWSER_WINDOWS = Dict{String,Any}()
const BROWSER_WINDOWS_LOCK = ReentrantLock()
const BROWSER_WINDOW_INFO = Dict{String,NamedTuple{(:url, :title),
                                                  Tuple{String,String}}}()
const BROWSER_WINDOW_INFO_LOCK = ReentrantLock()

browserWindowOpen(id::AbstractString) =
    lock(() -> haskey(BROWSER_WINDOWS, String(id)), BROWSER_WINDOWS_LOCK)

"""
    browserWindowInfo(id) -> (open, shown, url, title)

Diagnostics for probes/UI: whether a native window exists, is visible, and the
last URL/title reported by its page.
"""
function browserWindowInfo(id::AbstractString)
    key = String(id)
    bw = lock(() -> get(BROWSER_WINDOWS, key, nothing), BROWSER_WINDOWS_LOCK)
    info = lock(() -> get(BROWSER_WINDOW_INFO, key, (url = "", title = "")),
                BROWSER_WINDOW_INFO_LOCK)
    shown = false
    if bw !== nothing
        shown = try
            Webviews.API.is_shown(bw)
        catch
            false
        end
    end
    return (open = bw !== nothing, shown = shown, url = info.url, title = info.title)
end

@static if Sys.isapple()
    const _NSWINDOW_STYLE = UInt64(1 | 2 | 4 | 8)   # titled|closable|miniaturizable|resizable

    "Create a bare NSWindow (owned by Webviews once filled); main thread only."
    function _newBrowserNSWindow(width::Int, height::Int)
        cls = ccall(:objc_getClass, Ptr{Cvoid}, (Cstring,), "NSWindow")
        alloc = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), "alloc")
        win = ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), cls, alloc)
        rect = Webviews.PlatformImpl.CGRect(0, 0, width, height)
        sel = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,),
                    "initWithContentRect:styleMask:backing:defer:")
        win = ccall(:objc_msgSend, Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}, Webviews.PlatformImpl.CGRect,
                     UInt64, UInt64, Bool),
                    win, sel, rect, _NSWINDOW_STYLE, UInt64(2), false)
        # A closed NSWindow is normally deallocated; Webviews' finalizer calls
        # is_shown() on the handle and then dereferences freed memory (SIGSEGV
        # measured). Keep the window object alive; we destroy it explicitly.
        ccall(:objc_msgSend, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Bool),
              win, ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,),
                         "setReleasedWhenClosed:"), false)
        return win
    end

    const BROWSER_REPORT_JS = """
    (function () {
      function report() {
        try {
          if (window.flootyBrowserNativeReport)
            window.flootyBrowserNativeReport(document.title || '',
                                             location.href || '');
        } catch (e) {}
      }
      window.addEventListener('load', report);
      setTimeout(report, 400);
    })();
    """

    "Create + navigate the native window. MAIN THREAD ONLY."
    function _createBrowserWindowOnMain!(key::String, url::String, name::String,
                                         width::Int, height::Int)
        lock(BROWSER_WINDOWS_LOCK) do
            haskey(BROWSER_WINDOWS, key) && return nothing
        end
        win = _newBrowserNSWindow(width, height)
        bw = Webviews.Webview((width, height);
                              title = isempty(name) ? "Flooty Browser" : name,
                              unsafe_window_handle = win,
                              enable_webio = false,
                              auto_terminate = false)
        # Page title/url → registry (and the window title, for orientation).
        Webviews.bind(bw, "flootyBrowserNativeReport") do args
            title = length(args) >= 1 ? string(args[1]) : ""
            href = length(args) >= 2 ? string(args[2]) : url
            lock(BROWSER_WINDOW_INFO_LOCK) do
                BROWSER_WINDOW_INFO[key] = (url = href, title = title)
            end
            if !isempty(title)
                try Webviews.title!(bw, title) catch end
            end
            return nothing
        end
        Webviews.init!(bw, BROWSER_REPORT_JS)
        Webviews.navigate!(bw, url)
        lock(BROWSER_WINDOWS_LOCK) do
            BROWSER_WINDOWS[key] = bw
        end
        lock(BROWSER_WINDOW_INFO_LOCK) do
            BROWSER_WINDOW_INFO[key] = (url = url, title = name)
        end
        @debug "flootyWebUi: native browser window opened" id = key url
        return bw
    end
end

"""
    openBrowserWindow!(id, url; name = "", width = 1000, height = 760) -> Bool

Open (or focus + navigate) the native browser window for a BrowserSession.
No-op on non-Apple platforms or when no UI is live (the iframe remains).
"""
function openBrowserWindow!(id::AbstractString, url::AbstractString;
                            name::AbstractString = "",
                            width::Int = 1000, height::Int = 760)::Bool
    @static if Sys.isapple()
        main = activeTerminalUiWebview()
        main === nothing && return false
        key = String(id)
        lock(() -> haskey(BROWSER_WINDOWS, key), BROWSER_WINDOWS_LOCK) &&
            return navigateBrowserWindow!(key, url)
        Webviews.dispatch(main) do
            try
                _createBrowserWindowOnMain!(key, String(url), String(name), width, height)
            catch err
                @debug "flootyWebUi: native browser window create failed" exception = err
            end
        end
        return true
    else
        return false
    end
end

"""
    navigateBrowserWindow!(id, url) -> Bool

Navigate the native window, recreating it if the user closed it. Falls back to
opening when no window is registered yet.
"""
function navigateBrowserWindow!(id::AbstractString, url::AbstractString)::Bool
    @static if Sys.isapple()
        key = String(id)
        bw = lock(() -> get(BROWSER_WINDOWS, key, nothing), BROWSER_WINDOWS_LOCK)
        bw === nothing && return openBrowserWindow!(key, url)
        main = activeTerminalUiWebview()
        main === nothing && return false
        Webviews.dispatch(main) do
            try
                shown = try
                    Webviews.API.is_shown(bw)
                catch
                    false
                end
                if !shown
                    lock(BROWSER_WINDOWS_LOCK) do
                        get(BROWSER_WINDOWS, key, nothing) === bw &&
                            delete!(BROWSER_WINDOWS, key)
                    end
                    try Webviews.destroy(bw) catch end
                    _createBrowserWindowOnMain!(key, String(url), "Flooty Browser",
                                                1000, 760)
                else
                    Webviews.navigate!(bw, String(url))
                    lock(BROWSER_WINDOW_INFO_LOCK) do
                        old = get(BROWSER_WINDOW_INFO, key, (url = "", title = ""))
                        BROWSER_WINDOW_INFO[key] = (url = String(url), title = old.title)
                    end
                end
            catch err
                @debug "flootyWebUi: native browser navigate failed" exception = err
            end
        end
        return true
    else
        return false
    end
end

"Close one session's native window (no-op when absent)."
function closeBrowserWindow!(id::AbstractString)::Bool
    key = String(id)
    bw = lock(BROWSER_WINDOWS_LOCK) do
        pop!(BROWSER_WINDOWS, key, nothing)
    end
    lock(BROWSER_WINDOW_INFO_LOCK) do
        pop!(BROWSER_WINDOW_INFO, key, nothing)
    end
    bw === nothing && return false
    if terminalUiRunning[] && activeTerminalUiWebview() !== nothing
        Webviews.dispatch(activeTerminalUiWebview()) do
            try Webviews.destroy(bw) catch end
        end
    else
        try Webviews.destroy(bw) catch end
    end
    return true
end

"Close every native browser window (app teardown)."
function closeAllBrowserWindows!()
    ids = lock(() -> collect(keys(BROWSER_WINDOWS)), BROWSER_WINDOWS_LOCK)
    for key in ids
        closeBrowserWindow!(key)
    end
    return nothing
end
