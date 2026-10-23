# copySelectionProbe.jl — ⌘C must put the LIVE SELECTION on the pasteboard, and ⌘V
# must deliver the clipboard to the focused caret (assist editor or xterm).
#
# WebKit's OWN editing commands are inert in this process (measured with real key
# events: ⌘C collapses the selection and leaves the pasteboard untouched, ⌘V does
# nothing), so the app owns both:
#   * the page reports its live selection (reportSelection / xterm onSelectionChange)
#     and ⌘C asks it to copy — execCommand('copy') runs where writes are granted;
#   * ⌘V reads the clipboard in Julia and hands it back to the page, which inserts
#     it at the caret (CodeMirror replaceSelection, or xterm paste).
# installEditingKeyHandler! takes both keys over in -[NSApplication sendEvent:].
#
# Every key is posted through -[NSApplication sendEvent:], the same path a real key
# press takes. The pasteboard is restored afterwards, so running this never eats
# the user's clipboard.
#
# Requires a desktop session (opens the native window).
#
# Run: julia --startup-file=no --project=. test/copySelectionProbe.jl
# Verdict line on stdout: [COPY-PROBE] {"failed":N,"checks":M}
import FlootyPTYLayer
using FlootyPTYLayer
import Webviews

const ID = Ptr{Cvoid}
sel(name::AbstractString) = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), name)
cls(name::AbstractString) = ccall(:objc_getClass, Ptr{Cvoid}, (Cstring,), name)
msg0(recv::Ptr{Cvoid}, s::AbstractString) =
    ccall(:objc_msgSend, ID, (Ptr{Cvoid}, Ptr{Cvoid}), recv, sel(s))

# The pasteboard is touched from TASKS, never from a timer callback: a callback
# that blocks stops the run loop that delivers selection pings and performs copies.
const CLIP = Ref("")
function readClipboard()
    @async begin
        CLIP[] = try
            read(`pbpaste`, String)
        catch e
            ""
        end
    end
    return nothing
end
function writeClipboard(text::AbstractString)
    @async begin
        try
            open(`pbcopy`, "w") do io
                write(io, text)
            end
        catch e
        end
    end
    return nothing
end

"Post a ⌘<char> key-down/key-up the way a key press reaches the app."
function postCommandKey(wv, char::AbstractString)
    app = msg0(cls("NSApplication"), "sharedApplication")
    win = Webviews.window_handle(wv)
    winNum = ccall(:objc_msgSend, Clong, (Ptr{Cvoid}, Ptr{Cvoid}), win, sel("windowNumber"))
    chars = ccall(:objc_msgSend, ID, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring), cls("NSString"),
                  sel("stringWithUTF8String:"), char)
    ev = ccall(:objc_msgSend, ID,
               (Ptr{Cvoid}, Ptr{Cvoid}, Clong, NTuple{2, Cdouble}, Culong, Cdouble,
                Clong, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, Cushort),
               cls("NSEvent"), sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
               Clong(10), (0.0, 0.0), Culong(1 << 20), 0.0, winNum, C_NULL,
               chars, chars, 0, Cushort(8))
    ccall(:objc_msgSend, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), app,
          sel("sendEvent:"), ev)
    return nothing
end

postCommandC(wv) = postCommandKey(wv, "c")
postCommandV(wv) = postCommandKey(wv, "v")

readClipboard()
const BEFORE = Ref("")

failures = String[]
checks = Ref(0)
function check(name::String, ok::Bool; detail::String = "")
    checks[] += 1
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

wv = launchTerminalUI()
report = Ref("")
Webviews.bind(wv, "probeCopyReport") do args
    report[] = args isa Tuple && !isempty(args) ? String(args[1]) : ""
    return "{\"success\":true}"
end
closeWv() = (try Webviews.close(wv) catch e; FlootyPTYLayer.requestStopEventLoop!(wv) end; nothing)
probe(mark, fn) = (report[] = mark; Webviews.eval!(wv, fn))

# ---------------------------------------------------------------- chat: copy
# A synthetic tab drives the transcript (the page's own tab may still be booting).
const SELECT_CHAT_JS = """
(function () {
  const info = { term: { write(){}, getSelection(){ return ''; } }, fitAddon: { fit(){} },
                 name: 'probe', juliaId: 'probe-sid', view: 'user', exited: false,
                 popups: [], chat: [] };
  terminals['term-copy-probe'] = info; activeTerminalId = 'term-copy-probe';
  window.handleAgentEvent('probe-sid', { kind: 'text', text: 'COPY_PROBE_CHAT' });
  const bubble = document.querySelector('#agentChatLog .chat-bubble');
  if (!bubble) return probeCopyReport(JSON.stringify({ error: 'no bubble' }));
  const range = document.createRange(); range.selectNodeContents(bubble);
  const s = window.getSelection(); s.removeAllRanges(); s.addRange(range);
  // No focus change here: focusing another element collapses the selection, and the
  // app copies what the PAGE REPORTS — the page must still hold it.
  return probeCopyReport(JSON.stringify({ selected: s.toString() }));
})()
"""

# The page may still be parsing when the first step fires, and the selection ping
# is debounced — retry both instead of assuming a fixed delay.
# The page has to have parsed before anything can be selected in it: gate the run
# on a readiness probe instead of guessing a load delay.
function stepWaitPage(attempt::Int = 0)
    probe("page-ready", """
    (function () {
      return probeCopyReport(JSON.stringify({
        ready: typeof window.handleAgentEvent === 'function' &&
               !!document.getElementById('agentChatLog') &&
               typeof window.flootyCopySelection === 'function' &&
               typeof window.flootyPaste === 'function' &&
               // The page's own first tab must be BOUND: while it boots (fit, focus,
               // begin_live) the document selection gets cleared under us.
               Object.values(terminals).some(i => i.juliaId)
      }));
    })()
    """)
    Webviews.set_timeout(() -> stepAfterWaitPage(attempt), wv, 0.4)
end

function stepAfterWaitPage(attempt::Int)
    if !occursin("\"ready\":true", report[]) && attempt < 40
        Webviews.set_timeout(() -> stepWaitPage(attempt + 1), wv, 0.4)
        return
    end
    # One settle tick after readiness: the tab that just bound stops touching
    # focus/selection, so the selection we are about to make survives to the key press.
    Webviews.set_timeout(stepSelectChat, wv, 1.5)
end

function stepSelectChat(attempt::Int = 0)
    probe("chat-select", SELECT_CHAT_JS)
    Webviews.set_timeout(() -> stepAfterSelect(attempt), wv, 0.5)
end

function stepAfterSelect(attempt::Int)
    if !occursin("COPY_PROBE_CHAT", report[]) && attempt < 12
        Webviews.set_timeout(() -> stepSelectChat(attempt + 1), wv, 0.4)
        return
    end
    stepCopyChat()
end

function stepCopyChat(attempt::Int = 0)
    if !occursin("COPY_PROBE_CHAT", FlootyPTYLayer.LIVE_SELECTION[]) && attempt < 8
        Webviews.set_timeout(() -> stepCopyChat(attempt + 1), wv, 0.4)
        return
    end
    BEFORE[] = CLIP[]
    check("the chat selection reaches the app",
          occursin("COPY_PROBE_CHAT", FlootyPTYLayer.LIVE_SELECTION[]);
          detail = repr(FlootyPTYLayer.LIVE_SELECTION[]))
    postCommandC(wv)
    Webviews.set_timeout(() -> (readClipboard(); Webviews.set_timeout(stepVerifyChat, wv, 0.4)), wv, 0.4)
end

# The copy is asynchronous (eval -> page -> pasteboard): keep re-reading the
# clipboard for a moment before calling it a failure.
function stepVerifyChat(attempt::Int = 0)
    if !occursin("COPY_PROBE_CHAT", CLIP[]) && attempt < 20
        readClipboard()
        Webviews.set_timeout(() -> stepVerifyChat(attempt + 1), wv, 0.4)
        return
    end
    check("⌘C copies the CHAT selection to the pasteboard",
          occursin("COPY_PROBE_CHAT", CLIP[]); detail = repr(first(CLIP[], 60)))
    Webviews.eval!(wv, """
    (function () {
      const key = Object.keys(terminals).find(k => k !== 'term-copy-probe');
      if (key) switchToTerminal(key);          // the pane must be the ACTIVE tab
      const info = terminals[key];
      if (!info || !info.term || !info.term.buffer) return probeCopyReport(JSON.stringify({ noPane: true }));
      const s = window.getSelection(); s.removeAllRanges();
      // Select a row that actually HAS text: a freshly booted pane may still be blank
      // on the cursor row, which would make the "selection" empty.
      const b = info.term.buffer.active;
      let row = -1, len = 0;
      for (let y = 0; y < b.length; y++) {
        const line = b.getLine(y);
        if (!line) continue;
        const t = line.translateToString(false).replace(/\\s+\$/, '');
        if (t.length > 3) { row = y; len = t.length; break; }
      }
      if (row >= 0) info.term.select(0, row, len);
      return probeCopyReport(JSON.stringify({ selected: info.term.getSelection(), row: row }));
    })()
    """)
    Webviews.set_timeout(stepCopyTerm, wv, 0.8)
end

# ----------------------------------------------------------- terminal: copy
function stepCopyTerm(attempt::Int = 0)
    # The pane has to have text to select, and the ping is debounced: retry both.
    empty = isempty(FlootyPTYLayer.LIVE_SELECTION[]) ||
            occursin("COPY_PROBE_CHAT", FlootyPTYLayer.LIVE_SELECTION[])
    if !occursin("noPane", report[]) && empty && attempt < 10
        Webviews.eval!(wv, """
        (function () {
          const key = Object.keys(terminals).find(k => k !== 'term-copy-probe');
          const info = key ? terminals[key] : null;
          if (!info) return probeCopyReport(JSON.stringify({ noPane: true }));
          const b = info.term.buffer.active;
          let row = -1, len = 0;
          for (let y = 0; y < b.length; y++) {
            const line = b.getLine(y);
            if (!line) continue;
            const t = line.translateToString(false).replace(/\\s+\$/, '');
            if (t.length > 3) { row = y; len = t.length; break; }
          }
          if (row >= 0) info.term.select(0, row, len);
          return probeCopyReport(JSON.stringify({ selected: info.term.getSelection(), row: row }));
        })()
        """)
        Webviews.set_timeout(() -> stepCopyTerm(attempt + 1), wv, 0.4)
        return
    end
    if occursin("noPane", report[])
        println("SKIP  no real terminal pane yet — terminal copy/paste not exercised")
        Webviews.set_timeout(stepPasteAssist, wv, 0.2)
        return
    end
    check("the terminal selection reaches the app (xterm keeps its own)",
          !isempty(FlootyPTYLayer.LIVE_SELECTION[]) &&
          !occursin("COPY_PROBE_CHAT", FlootyPTYLayer.LIVE_SELECTION[]);
          detail = repr(FlootyPTYLayer.LIVE_SELECTION[]))
    postCommandC(wv)
    Webviews.set_timeout(() -> (readClipboard(); Webviews.set_timeout(stepVerifyTerm, wv, 0.4)), wv, 0.4)
end

function stepVerifyTerm(attempt::Int = 0)
    if CLIP[] != first(FlootyPTYLayer.LIVE_SELECTION[], 60) && attempt < 20
        readClipboard()
        Webviews.set_timeout(() -> stepVerifyTerm(attempt + 1), wv, 0.4)
        return
    end
    check("⌘C copies the TERMINAL selection to the pasteboard",
          CLIP[] == first(FlootyPTYLayer.LIVE_SELECTION[], 60); detail = repr(first(CLIP[], 60)))
    writeClipboard("PASTE_PROBE_TEXT")
    Webviews.set_timeout(stepPasteAssist, wv, 0.4)
end

# ------------------------------------------------------------ assist: paste
function stepPasteAssist()
    probe("assist-focus", """
    (function () {
      try { assistCm.setValue(''); } catch (e) {}
      try { assistCm.focus(); } catch (e) {}
      const a = document.activeElement;
      return probeCopyReport(JSON.stringify({
        inAssistBar: !!(a && a.closest && a.closest('#assistBar')) }));
    })()
    """)
    Webviews.set_timeout(stepFirePasteAssist, wv, 0.4)
end

function stepFirePasteAssist()
    occursin("\"inAssistBar\":true", report[]) || println(
        "NOTE  assist editor did not take focus: ", report[])
    postCommandV(wv)
    Webviews.set_timeout(stepVerifyPasteAssist, wv, 0.8)
end

function stepVerifyPasteAssist()
    Webviews.eval!(wv, """
    (function () {
      let value = '';
      try { value = assistCm.getValue(); } catch (e) {}
      return probeCopyReport(JSON.stringify({ editor: value }));
    })()
    """)
    Webviews.set_timeout(stepCheckPasteAssist, wv, 0.4)
end

function stepCheckPasteAssist()
    check("⌘V pastes into the assist editor",
          occursin("PASTE_PROBE_TEXT", report[]); detail = String(first(report[], 120)))
    Webviews.eval!(wv, """
    (function () {
      try { assistCm.setValue(''); } catch (e) {}
      const key = Object.keys(terminals).find(k => k !== 'term-copy-probe');
      if (key) switchToTerminal(key);          // focus follows the ACTIVE tab
      const info = terminals[key];
      if (!info || !info.term || !info.term.focus) return probeCopyReport(JSON.stringify({ noPane: true }));
      info.term.focus();
      const a = document.activeElement;
      return probeCopyReport(JSON.stringify({ focused: true,
        inAssistBar: !!(a && a.closest && a.closest('#assistBar')) }));
    })()
    """)
    Webviews.set_timeout(stepFirePasteTerm, wv, 0.4)
end

# -------------------------------------------------------- terminal: paste
function stepFirePasteTerm()
    occursin("\"inAssistBar\":true", report[]) && println(
        "NOTE  focus stayed in the assist bar: ", report[])
    if occursin("noPane", report[])
        println("SKIP  terminal paste (no pane)")
        return stepFinishProbe()
    end
    postCommandV(wv)
    Webviews.set_timeout(stepVerifyPasteTerm, wv, 1.0)
end

function stepVerifyPasteTerm()
    Webviews.eval!(wv, """
    (function () {
      const info = terminals[Object.keys(terminals).find(k => k !== 'term-copy-probe')];
      const b = info.term.buffer.active;
      let text = '';
      for (let y = 0; y < b.length; y++) {
        const line = b.getLine(y);
        if (line) text += line.translateToString(false) + '\\\\n';
      }
      return probeCopyReport(JSON.stringify({ hasMarker: text.indexOf('PASTE_PROBE_TEXT') >= 0 }));
    })()
    """)
    Webviews.set_timeout(stepCheckPasteTerm, wv, 0.5)
end

function stepCheckPasteTerm()
    check("⌘V pastes into the terminal (xterm paste reaches the pane)",
          occursin("\"hasMarker\":true", report[]); detail = String(first(report[], 120)))
    stepFinishProbe()
end

function stepFinishProbe()
    isempty(BEFORE[]) || writeClipboard(BEFORE[])   # leave the machine as found
    Webviews.set_timeout(closeWv, wv, 0.6)
end

Webviews.set_timeout(stepWaitPage, wv, 1.5)
Webviews.set_timeout(() -> (println("WATCHDOG: closing the window"); closeWv()), wv, 120.0)
FlootyPTYLayer.runEventLoopAndTeardown!(wv)

println("[COPY-PROBE] {\"failed\":", length(failures), ",\"checks\":", checks[], "}")
isempty(failures) || (println("FAILED CHECKS: ", join(failures, ", ")); exit(1))
println("COPY_SELECTION_PROBE_OK")
exit(0)
