# session.jl — ReplSession glues the PTY layer and FlootyREPLBridge into the
# duplex loop: REPL flavor detection on startup, agentWriteAndWait
# (wrap → write → tail output for the END sentinel → EvalOutcome with
# errorKind + duration), always-allowed user writes, control gating,
# WaitForEval callbacks, and the .warp/repl-status.md status sidecar.
#
# Output tailing model: a single background consumer task drains the PTY's
# output channel into a rolling buffer, parses sentinels out of every new
# chunk, and notifies per-eval Conditions. agentWriteAndWait waits on its
# eval's condition — no polling from the caller's side.
import FlootyREPLBridge

"""Tailing state shared between the reader task and waiters."""
mutable struct OutputTail
    buf::Vector{UInt8}
    maxBytes::Int
    lock::ReentrantLock
    # Absolute stream offset of buf[1]: bytes trimmed off the front still count,
    # so callers can name positions that outlive the rolling window.
    base::Int
end
OutputTail(maxBytes::Int = 1 << 20) =
    OutputTail(Vector{UInt8}(), maxBytes, ReentrantLock(), 0)

function tailAppend!(t::OutputTail, chunk::Vector{UInt8})
    lock(t.lock) do
        append!(t.buf, chunk)
        overflow = length(t.buf) - t.maxBytes
        if overflow > 0
            deleteat!(t.buf, 1:overflow)
            t.base += overflow
        end
    end
    return t
end

tailText(t::OutputTail) =
    lock(() -> String(copy(t.buf)), t.lock)

"Absolute stream offset of the current END (what a later `tailTextFrom` can name)."
tailEnd(t::OutputTail) = lock(() -> t.base + length(t.buf), t.lock)

"""
    tailTextFrom(t, from) :: String

Tail text from absolute stream offset `from` to the current end. A `from` older
than the trim point clamps to the oldest byte still held — bytes the rolling
window has dropped are gone for good.
"""
function tailTextFrom(t::OutputTail, from::Integer)::String
    return lock(t.lock) do
        off = max(Int(from), t.base) - t.base
        off >= length(t.buf) && return ""
        String(t.buf[(off + 1):end])
    end
end

"""
    tailLastLine(t; maxBytes = 4096) :: String

The tail's last line, verbatim (no ANSI scrubbing): the bytes after the last
`'\\n'` inside the newest `maxBytes`, with trailing line breaks dropped. A
prompt check needs only this, at a cost bounded by line length instead of tail
length.
"""
function tailLastLine(t::OutputTail; maxBytes::Int = 4096)::String
    return lock(t.lock) do
        stop = length(t.buf)
        while stop > 0 && (t.buf[stop] == 0x0a || t.buf[stop] == 0x0d)
            stop -= 1
        end
        stop == 0 && return ""
        from = max(1, stop + 1 - maxBytes)
        while from <= stop && (t.buf[from] & 0xc0) == 0x80
            from += 1                     # never start inside a UTF-8 character
        end
        cut = from - 1
        for i in from:stop
            t.buf[i] == 0x0a && (cut = i)
        end
        String(t.buf[(cut + 1):stop])
    end
end

"""One pending evaluation tracked by a ReplSession."""
mutable struct PendingEval
    id::String
    cond::Condition
    done::Bool
    outcome::Union{EvalOutcome,Nothing}
end

"""OSC 133 lifecycle marks seen in the RAW PTY stream (pre-ANSI-strip —
the terminal must not eat them; we scan before any display scrubbing).
`beginPos`: byte offset of the most recent C (output-start) mark's position
in the raw stream; `pendingOpen`: a C was seen and its D is awaited."""
mutable struct OscMarkState
    beginPos::Int
    pendingOpen::Bool
end
OscMarkState() = OscMarkState(0, false)

"""
A live REPL session: PTY handle + bridge registry + control machine + tailer.
Construct via `startReplSession`.
"""
mutable struct ReplSession
    pty::PtyHandle
    registry::EvalRegistry
    control::ControlState
    flavor::Union{ReplFlavor,Nothing}
    # The command line this session was spawned from (e.g. "julia -q" or
    # "/bin/zsh -i") — the authoritative kind signal even before/without
    # banner-based flavor detection (generic-terminal model).
    cmd::String
    pending::Dict{String,PendingEval}
    tail::OutputTail
    sidecarPath::String
    readerTask::Union{Task,Nothing}
    closed::Bool
    lock::ReentrantLock
    # Per-chunk observers (e.g. the WebView UI when it adopts a live session).
    # Called from the reader task AFTER tail append; exceptions are swallowed.
    outputTaps::Vector{Function}
    # OSC 133 shell-integration state (generic-terminal model): when the
    # spawned shell emits A/C/D marks, evals resolve from REAL command
    # boundaries + exit codes instead of typed sentinel wrappers.
    osc::OscMarkState
    oscSeen::Bool          # true once ANY 133 mark observed on this session
    oscRawBuf::Vector{UInt8}   # rolling raw tail for mark scanning
    # Alternate-screen state (DECSET ?1049h/?1047h/?47h). A full-screen TUI
    # (broot, vim, htop, fzf, lazygit, less -F …) owns the keyboard: typing a
    # sentinel wrapper into it just feeds the wrapper's characters to the app as
    # KEYSTROKES ("I see keyinputs in the broot"). While this is true the agent
    # writes plain, and evals resolve as STARTED rather than waiting for a
    # sentinel the TUI will never print on its own line.
    altScreen::Bool
    altSeen::Bool
    altCarry::Vector{UInt8}
    # Absolute stream offset the NEXT sentinel parse must start from: the start
    # of the last BEGIN with no END after it (an eval still in flight), else the
    # start of the last (possibly half-received) line. Bounds the per-chunk parse
    # to the unresolved region instead of the whole tail.
    sentinelFrom::Int
end

const DEFAULT_EVAL_TIMEOUT_S = 60.0
# Prompt-watch: output must be quiet this long, with the shell's prompt back,
# before an eval is considered finished.
const PROMPT_QUIET_S = 0.15
const PROMPT_TIMEOUT_S = 90.0
const DEFAULT_SIDECAR = joinpath(".warp", "repl-status.md")

# Rolling raw-stream window kept for OSC 133 scanning (marks are tiny; the
# window only needs to span one chunk boundary's worth of context).
const OSC_RAW_WINDOW = 1 << 16
# No command is open: the only bytes that matter are a possible mark split
# across a chunk boundary. Keeping the whole 64 KiB window made every redraw
# chunk (micro/broot) copy and regex-scan 64 KiB even with no OSC 133 in sight.
const OSC_CARRY_BYTES = 64

# ZDOTDIR shim: makes every spawned zsh emit OSC 133 A/C/D around each
# command WITHOUT touching the user's rc files. The user's own zshrc still
# loads (ZDOTDIR points at a dir whose .zshrc sources the original), so
# prompts/themes stay stock. D carries the real exit code; C opens an output
# region the tailer pairs against D to resolve agent evals.
function _oscHookDir()
    dir = abspath(joinpath(homedir(), ".cache", "flooty", "zdotdir"))
    mkpath(dir)
    rcPath = joinpath(dir, ".zshrc")
    if !isfile(rcPath) ||
       !occursin("FLOOTY_OSC133", read(rcPath, String))
        open(rcPath, "w") do f
            println(f, "# FLOOTY_OSC133 v1 - auto-injected shell integration")
            println(f, "# Source the user's real zshrc (ZDOTDIR was redirected).")
            println(f, "setopt no_insecure_rcs 2>/dev/null || true")
            println(f, "[[ -f \$HOME/.zshrc ]] && source \$HOME/.zshrc")
            println(f, "flooty_precmd()  { printf '\\e]133;D;%d\\a' \$?; " *
                         "printf '\\e]133;A\\a' }")
            println(f, "flooty_preexec() { printf '\\e]133;C\\a' }")
            println(f, "precmd_functions+=(flooty_precmd)")
            println(f, "preexec_functions+=(flooty_preexec)")
        end
    end
    return dir
end

"""Env overrides implementing the generic-terminal shell-integration
bootstrap (Warp model): zsh gets our ZDOTDIR shim; other shells pass
through untouched (bash/fish hooks are future work)."""
function _integrationEnvs(cmd::Cmd)
    exe = first(normalizeCmdFields(cmd).exec)
    occursin(r"(?:^|/)zsh(?:\z|\$)", exe) || return nothing
    # ONLY the delta: startReplSession deletes every key in this dict from the
    # parent ENV after spawning, so copying all of ENV here would erase the
    # whole parent environment (PATH, HOME, ...) after the first shell spawn.
    return Dict{String,String}("ZDOTDIR" => _oscHookDir())
end

"Wait until `pred(text)` holds; returns (text, matched). Used at startup only."
function waitForText(getText::Function, pred::Function; timeoutS::Float64,
                     label::String)
    deadline = time() + timeoutS
    while true
        text = getText()
        if !isempty(strip(text)) && pred(text)
            return (text, true)
        end
        time() >= deadline && return (text, false)
        sleep(0.02)
    end
end

"""
    startReplSession(cmd::Cmd; rows=24, cols=80,
                    sidecarPath=".warp/repl-status.md",
                    waitPrompt=true) :: ReplSession

Spawn `cmd` attached to a PTY and start the sentinel-parsing tailer. By
default this BLOCKS until a Julia prompt/banner appears and classifies the
session flavor — right for adoptions and headless sessions, WRONG for the
WebView bindings (they run on the MAIN THREAD; blocking here froze the entire
GUI for a full julia boot on every "+ New Terminal" ). Pass
`waitPrompt = false` to return immediately; the caller owns boot completion
(prompt detection + `sess.flavor`) — see `handleTerminalCreate`.
"""
function startReplSession(cmd::Cmd; rows::Int = 24, cols::Int = 80,
                          sidecarPath::AbstractString = DEFAULT_SIDECAR,
                          waitPrompt::Bool = true)
    haskey(ENV, "TERM") || (ENV["TERM"] = "xterm-256color")
    haskey(ENV, "COLORTERM") || (ENV["COLORTERM"] = "truecolor")
    envOverrides = _integrationEnvs(cmd)
    pty = envOverrides === nothing ? spawnPty(cmd; rows, cols) :
          withenv(() -> begin
              merge!(ENV, envOverrides)
              try
                  spawnPty(cmd; rows, cols)
              finally
                  for k in keys(envOverrides)
                      haskey(ENV, k) && delete!(ENV, k)
                  end
              end
          end)
    sess = ReplSession(pty, EvalRegistry(), ControlState(:shared), nothing,
                       string(join(normalizeCmdFields(cmd).exec, " ")),
                       Dict{String,PendingEval}(), OutputTail(),
                       String(sidecarPath), nothing, false, ReentrantLock(),
                       Function[], OscMarkState(), false, Vector{UInt8}(),
                       false, false, Vector{UInt8}(), 0)
    sess.readerTask = @async sessionReaderLoop(sess)
    if waitPrompt
        (_, ok) = waitForText(() -> tailText(sess.tail),
                              t -> occursin("julia>", t) ||
                                  detectReplFlavor(t) !== nothing;
                              timeoutS = PROMPT_TIMEOUT_S,
                              label = "repl-startup")
        ok || @warn "startReplSession: no Julia prompt detected within $PROMPT_TIMEOUT_S s"
        sess.flavor = detectReplFlavor(tailText(sess.tail))
    end
    return sess
end

"""
Background consumer: drains the PTY channel into the tail buffer and resolves
pending evals as END sentinels arrive. Exits when the channel closes.
"""
function sessionReaderLoop(sess::ReplSession)
    ch = outputChannel(sess.pty)
    while isopen(ch)
        chunk = try
            take!(ch)
        catch
            break  # closed while blocked in take!
        end
        tailAppend!(sess.tail, chunk)
        trackAltScreen!(sess, chunk)
        # NOTIFY THE UI FIRST, THEN RESOLVE. Evals used to be resolved before the
        # output taps ran, so the agent loop could wake, ask the page for the
        # rendered viewport, and get the screen from BEFORE the chunk it had just
        # produced — the model then re-sent work whose result was already on
        # screen (the observed sed repetition). The taps post the chunk to the
        # page; resolution (and therefore the next snapshot) happens after, and
        # the page's own report request is FIFO behind that write.
        # Taps are typically closures defined AFTER this task started running, so
        # they must be invoked with `invokelatest` — a plain call fails with a
        # world-age MethodError that the catch below would silently swallow.
        for tap in sess.outputTaps
            try
                Base.invokelatest(tap, chunk)
            catch err
                @debug "sessionReaderLoop: output tap failed" exception = err
            end
        end
        # Full-screen USER apps (micro, broot, vim, less) emit a redraw stream
        # with no shell sentinels. Scanning the whole unresolved tail on every
        # chunk made the reader copy/parse up to 1 MiB per redraw, competing
        # with keystroke delivery. The shell integration marks only resume
        # meaning when the shell owns input again (after the app exits).
        userApp = try
            sess.altScreen && currentState(sess.control) == :user
        catch
            false
        end
        if !userApp
            processOsc133!(sess, chunk)
            notifySentinels!(sess)
        end
    end
    # Channel closed: fail any still-pending evals so callers never hang forever.
    lock(sess.lock) do
        for pe in values(sess.pending)
            if !pe.done
                pe.done = true
                pe.outcome = EvalOutcome(evalId = pe.id, ok = false,
                                         excerpt = "session closed before eval finished",
                                         errorKind = :other, duration = 0.0)
                notify(pe.cond)
            end
        end
        empty!(sess.pending)
    end
    return nothing
end

# Full token prefixes (`marker*tag`): sentinels are always PRINTED on their own
# line, so a region boundary never has to fall inside a token.
const _SENTINEL_BEGIN_FULL =
    string(FlootyREPLBridge._SENTINEL_MARKER, FlootyREPLBridge._BEGIN_TAG)
const _SENTINEL_END_FULL =
    string(FlootyREPLBridge._SENTINEL_MARKER, FlootyREPLBridge._END_TAG)

"""
Absolute stream offset the NEXT sentinel parse must start from, given the text
just parsed and the offset `from` it began at: the start of the last BEGIN with
no END after it (that eval is still in flight and its excerpt spans the region),
otherwise the start of the trailing partial line, which is held back so a token
split across chunks is re-parsed whole.
"""
function _sentinelOrigin(text::AbstractString, from::Int)::Int
    lb = findlast(_SENTINEL_BEGIN_FULL, text)
    le = findlast(_SENTINEL_END_FULL, text)
    hold = (lb !== nothing && (le === nothing || first(lb) > first(le))) ?
           from + first(lb) - 1 : from + ncodeunits(text)
    nl = findlast('\n', text)
    nl === nothing && return from          # one unterminated line: hold it all
    return min(hold, from + nl)
end

"""
Parse sentinels out of the UNRESOLVED tail region only, starting at
`sess.sentinelFrom` rather than the whole tail: a token can split across chunk
boundaries and an excerpt spans BEGIN..END, possibly many chunks apart, so a
region is retained from the last BEGIN still awaiting its END. Duplicate
deliveries are harmless — the first END hit resolves and deletes the pending
entry, so later rescans are no-ops.
"""
# A sentinel token arrives on its own line. With NO pending eval there is
# nothing to resolve, so only the newest window can contain a (future) token;
# never re-copy an unbounded un-newlined line (micro/broot redraws, `print`
# without a newline). With a pending eval the BEGIN may be arbitrarily far back,
# so keep the full unresolved region for its excerpt.
const SENTINEL_SCAN_TAIL_BYTES = 4096

function notifySentinels!(sess::ReplSession)
    t = sess.tail
    from = max(sess.sentinelFrom, t.base)
    if lock(() -> isempty(sess.pending), sess.lock)
        from = max(from, tailEnd(t) - SENTINEL_SCAN_TAIL_BYTES)
    end
    text = tailTextFrom(t, from)
    isempty(text) && return nothing
    sess.sentinelFrom = _sentinelOrigin(text, from)
    events = parseSentinels(codeunits(text))
    isempty(events) && return nothing
    lock(sess.lock) do
        for ev in events
            ev isa BeginEval && continue
            id = ev.evalId
            haskey(sess.pending, id) || continue
            pe = sess.pending[id]
            if !pe.done
                pe.done = true
                kind = ev.ok ? :none : classifyError(ev.excerpt)
                pe.outcome = EvalOutcome(evalId = id, ok = ev.ok,
                                         excerpt = ev.excerpt, errorKind = kind,
                                         duration = 0.0)
                notify(pe.cond)
            end
        end
    end
    return nothing
end

# ---- OSC 133 shell-integration (generic-terminal model) ---------------------

# A / C / D marks as they appear in the RAW byte stream (BEL-terminated;
# ST-terminated forms are matched too). D carries `;<exit-code>`.
const _OSC133_A_RE = r"\e\]133;A(?:\x07|\e\\)"
const _OSC133_C_RE = r"\e\]133;C(?:\x07|\e\\)"
const _OSC133_D_RE = r"\e\]133;D;(-?\d+)(?:\x07|\e\\)"

_oscDebug() = get(ENV, "FLOOTY_OSC_DEBUG", "0") == "1"
const OSC133_SRC_VERSION = "v4-destructive"
"Append one line to the env-gated OSC 133 trace log (stdout-independent)."
function _oscTrace(line::AbstractString)
    _oscDebug() || return nothing
    try
        open("/tmp/flooty_osc_dbg.log", "a") do f
            println(f, round(Int, time() * 1000), " ", line)
        end
    catch
    end
    return nothing
end

"""
    processOsc133!(sess, chunk)

Ingest one raw PTY chunk into the OSC 133 shell-integration state. Two jobs,
one window decode:

* TRACK the lifecycle marks. On the FIRST mark ever seen the session flips to
  mark-based resolution (`oscSeen`): from then on, agent evals resolve via C→D
  pairing and idle detection trusts the A prompt-start mark instead of guessing
  prompt glyphs. The C position is remembered so the excerpt can be cut out of
  the DISPLAY tail at resolve time.
* RESOLVE pending agent evals from D marks: the newest D after the open C closes
  the command region with the shell's REAL exit code. The excerpt is cut from the
  ANSI-stripped display tail between the C's echo position and the prompt line
  that follows the D — best-effort on either end.
"""
# Alternate-screen DECSET/DECRST: ?1049 (xterm's save/restore pair), ?1047 and
# ?47. Whatever sets `h` owns the screen; `l` gives it back.
const _ALT_SCREEN_RE = r"\e\[\?(?:1049|1047|47)([hl])"
const ALT_CARRY_BYTES = 16

"Track whether a full-screen TUI currently owns the terminal (see struct docs)."
function trackAltScreen!(sess::ReplSession, chunk::Vector{UInt8})
    lock(sess.lock) do
        text = String(vcat(sess.altCarry, chunk))
        lastMark = nothing
        for m in eachmatch(_ALT_SCREEN_RE, text)
            lastMark = m          # eachmatch is ordered: the final one wins
        end
        if lastMark !== nothing
            sess.altScreen = lastMark.captures[1] == "h"
            sess.altSeen = true
        end
        # Keep a small carry so a sequence split across chunks still matches.
        keep = String(last(text, ALT_CARRY_BYTES))
        sess.altCarry = Vector{UInt8}(codeunits(keep))
    end
    return nothing
end

inAltScreen(sess::ReplSession) = sess.altScreen

function processOsc133!(sess::ReplSession, chunk::Vector{UInt8})
    lock(sess.lock) do
        # Between commands nothing but a split mark can matter. An OPEN command
        # keeps the region from its C mark (needed for the excerpt + exit code).
        if !sess.osc.pendingOpen && length(sess.oscRawBuf) > OSC_CARRY_BYTES
            drop = length(sess.oscRawBuf) - OSC_CARRY_BYTES
            deleteat!(sess.oscRawBuf, 1:drop)
            sess.osc.beginPos = max(1, sess.osc.beginPos - drop)
        end
        append!(sess.oscRawBuf, chunk)
        _oscTrace("scan chunk=" * escape_string(String(copy(chunk))))
        overflow = length(sess.oscRawBuf) - OSC_RAW_WINDOW
        if overflow > 0
            deleteat!(sess.oscRawBuf, 1:overflow)
            # The window shifted: keep the remembered C offset consistent.
            sess.osc.beginPos = max(1, sess.osc.beginPos - overflow)
        end
        text = String(copy(sess.oscRawBuf))
        # --- mark tracking ----------------------------------------------------
        # Rescan is SAFE because resolution below consumes destructively: every
        # C/D pair up to the last resolved D has been trimmed out, so the
        # window only ever holds marks of the CURRENTLY OPEN region. Re-finding
        # the open C just re-asserts pendingOpen (idempotent).
        for m in eachmatch(_OSC133_C_RE, text)
            sess.osc.beginPos = m.offset
            sess.osc.pendingOpen = true
        end
        if occursin(_OSC133_A_RE, text) || occursin(_OSC133_D_RE, text) ||
           sess.osc.pendingOpen
            sess.oscSeen = true
        end
        # --- resolution -------------------------------------------------------
        sess.osc.pendingOpen || return nothing
        # Newest D in the raw window; ignore stale Ds emitted BEFORE the open C
        # (they belong to an earlier command region).
        d = nothing
        for m in eachmatch(_OSC133_D_RE, text)
            d = m   # eachmatch yields in order, so the final assignment wins
        end
        d === nothing && (_oscTrace("notify: no D yet"); return nothing)
        _oscTrace("notify: beginPos=$(sess.osc.beginPos) d=$(escape_string(d.match))")
        d.offset < sess.osc.beginPos && return nothing   # stale D from earlier command
        rc = parse(Int, only(d.captures))
        _oscTrace("resolve rc=$rc")
        sess.osc.pendingOpen = false
        # DESTRUCTIVE CONSUMPTION: drop the window up to and including this D.
        # The resolved C and D are gone, so future rescans cannot reopen the
        # old region nor let a later eval pair against the stale exit code.
        dEnd = d.offset + sizeof(d.match) - 1
        deleteat!(sess.oscRawBuf, 1:min(dEnd, length(sess.oscRawBuf)))
        sess.osc.beginPos = 0
        # Excerpt: ONLY this command's region. Cutting the WHOLE display tail
        # meant every eval reported the screen so far: an old "ERROR:" line made
        # every later command report err (observed: cat/sed failing forever), and
        # the model saw a previous command's output as this command's result.
        # The region starts after the shell's C mark (command started; the typed
        # echo is before it).
        local display::String
        try
            rawTail = FlootyPTYLayer.tailText(sess.tail)
            # Last C mark in the tail (Julia has no findlast(::Regex, ::String)).
            cpos = nothing
            for mm in eachmatch(_OSC133_C_RE, rawTail)
                cpos = mm
            end
            start = cpos === nothing ? 1 : cpos.offset + sizeof(cpos.match)
            region = start > lastindex(rawTail) ? "" : String(SubString(rawTail, start))
            display = _stripAnsi(region)
            display = length(display) > 20000 ? last(display, 20000) : display
        catch err
            # Never let an excerpt problem kill the reader (it resolves evals).
            @debug "OSC excerpt failed" exception = err
            display = ""
        end
        lines = split(display, '\n')
        while !isempty(lines) && isempty(strip(lines[end]))
            pop!(lines)
        end
        if !isempty(lines) && _tailAtIdlePrompt(strip(lines[end]))
            pop!(lines)
        end
        excerpt = strip(join(String.(lines), '\n'))
        isempty(excerpt) && (excerpt = "(no output)")
        ok = rc == 0 && !occursin(r"ERROR:", excerpt) &&
             !occursin("Traceback (most recent call last)", excerpt)
        for pe in values(sess.pending)
            pe.done && continue
            pe.done = true
            kind = ok ? :none : classifyError(excerpt)
            pe.outcome = EvalOutcome(evalId = pe.id, ok = ok, excerpt = excerpt,
                                     errorKind = kind, duration = 0.0)
            notify(pe.cond)
        end
        return nothing
    end
end

"""True when this session has demonstrated OSC 133 shell integration."""
oscIntegrated(sess::ReplSession) = sess.oscSeen

"""True when the OSC 133 stream says the shell is sitting at an idle prompt:
integration observed AND no command region currently open (C seen, D
awaited). Trusted over prompt-glyph guessing once marks flow — custom
prompts never break it."""
_oscAtIdlePrompt(sess::ReplSession) = sess.oscSeen && !sess.osc.pendingOpen

"Register a pending eval entry (caller holds sess.lock or is pre-spawn)."
function trackPendingEval!(sess::ReplSession, id::String)
    pe = PendingEval(id, Condition(), false, nothing)
    registerEval!(sess.registry, id)
    sess.pending[id] = pe
    return pe
end

"""Generate an eval id that survives echo round-trips (safe charset)."""
evalIdFor(n::Int) = string("eval", lpad(string(n), 6, '0'))

"""
    addOutputTap!(sess::ReplSession, tap::Function) :: Function

Observe every raw PTY chunk of this session from now on (`tap(bytes)`),
invoked from the reader task after the tail buffer updates. Used by the
WebView UI to forward an ADOPTED session's output to its window. Returns
`tap` for removal convenience.
"""
function addOutputTap!(sess::ReplSession, tap::Function)
    push!(sess.outputTaps, tap)
    return tap
end

"`addOutputTap!(sess) do chunk ... end` — do-block form of `addOutputTap!`."
addOutputTap!(tap::Function, sess::ReplSession) = addOutputTap!(sess, tap)

"Remove a previously installed output tap (idempotent)."
function removeOutputTap!(sess::ReplSession, tap::Function)
    filter!(f -> f !== tap, sess.outputTaps)
    return sess
end

"""
Build the PTY payload for one agent evaluation.

CRITICAL: the sentinel println sources are written PROGRAMMATICALLY —
`println(Char(0xf0a7), "FLOOTY_EVAL_BEGIN:", "<id>")` — never as one raw
token literal (marker and tag adjacent in the typed source). The tty echoes
every byte we type back into the output stream, so a raw-token END line in
the typed source would appear TWICE in the captured output: once in the
echo (immediately, BEFORE the evaluated error text is printed!) and once
in executed output. Resolving off the early echo loses the error excerpt.
With the programmatic form the echoed characters are plain ASCII
constructor code — marker and tag are never adjacent in the echo — so the
ONLY complete tokens in the stream come from actual executed output.

The TAG is split the same way (`"FLOOTY_" * "EVAL_BEGIN:"`), for the pane's
sake: the REPL repaints the typed line on EVERY keystroke, so the display
stream holds a sequence of partial redraws of one row, and a scrubber that
blanks the segment carrying the token leaves the PREVIOUS redraw on screen
— a truncated wrapper (`println('\uf0a7', "FLOOTY_EV`) that no later chunk
can erase. With the tag split, no echoed segment contains the complete
token, so nothing is blanked mid-row and the pane shows the plain, complete
typed line; the token still exists in the marker line the child PRINTS,
which is a whole line and blanked cleanly.

Like wrapWithSentinels, END is emitted unconditionally as `:ok`; the bridge
flips it based on `ERROR:` found in the excerpt between BEGIN and END.
"""
function agentPayload(code::AbstractString, evalId::AbstractString)
    body = String(code)
    endswith(body, '\n') || (body *= '\n')
    markerRepr = repr(Char(0xf0a7))                 # e.g. '\uf0a7' char literal
    beginLine = string("println(", markerRepr,
                       ", \"FLOOTY_\" * \"EVAL_BEGIN:\", \"", evalId, "\")")
    endLine = string("println(", markerRepr,
                     ", \"FLOOTY_\" * \"EVAL_END:\", \"", evalId,
                     "\", \":ok\")")
    return string(beginLine, '\n', body, endLine, '\n')
end

"""
    userWrite(sess::ReplSession, bytes::Vector{UInt8}) :: Int

Write raw bytes into the PTY attributed to the human. ALWAYS permitted, in
every control state — this is the duplex guarantee. User input interleaved
between sentinel lines does not affect eval pairing (ids match by token).
"""
userWrite(sess::ReplSession, bytes::Vector{UInt8}; source::Symbol = :user) =
    writeToPty(sess.pty, bytes; source = :user)

"Convenience: write a string as user input (always permitted)."
userWrite(sess::ReplSession, s::AbstractString) =
    writeToPty(sess.pty, Vector{UInt8}(codeunits(s)); source = :user)

# Strip ANSI/OSC control sequences so tail text can be matched by prompt. ONE
# `replace` with several patterns runs a single pass (each position tries the
# patterns in order) instead of re-walking the whole string per pattern.
function _stripAnsi(s::AbstractString)
    return replace(s,
                   r"\e\][^\x07]*\x07" => "",                        # OSC (BEL)
                   r"\e\][^\x07]*(\x07|\e\\)" => "",
                   r"\e\[[0-9;?]*[ -/]*[@-~]" => "",                 # CSI
                   r"\e[()][0-9A-Za-z]" => "",                       # designation/charset
                   r"\e." => "")                                     # leftover escapes
end

# Idle-prompt signatures of the REPL flavors we drive (generic-terminal
# model): julia's own prompt plus the common nested-REPL prompts (python,
# ipython, node) and shell prompts. Matched against the ANSI-stripped tail.
# NOTE: matching is on the RSTRIPPED text — trailing spaces are display
# noise and would otherwise force an exact-suffix miss.
const _IDLE_PROMPT_RES = (
    r"julia>\s*$",
    r">>>\s*$",                       # python
    r"In \[\d+\]:\s*$",             # ipython
    r"In :\s*$",                      # ipython after a crash (no counter)
    r"\.\.\.\.\.?\s*$",              # python/ipython continuation block
    r"[>\]]\s*$",                     # node (plain ">" (no outer ["))
    r"[%$#>]\s*$",                    # zsh / bash / generic shell
)
# Last-resort exact-suffix fallbacks (kept for exotic prompts the regexes
# above may miss).
const _LEGACY_IDLE_PROMPT_SUFFIXES =
    ("julia>", "\$", "%", "#", ">")

"""True when the ANSI-stripped tail ends in a known idle prompt. The tail is
rstripped FIRST: trailing spaces are display noise and exact suffix matches
against them never fire (the latent bug that made every write pay the full
two-second wait)."""
function _tailAtIdlePrompt(tailStr::AbstractString; bare_gt::Bool = true)
    stripped = rstrip(_stripAnsi(String(tailStr)))
    if !bare_gt
        # Shell PS2 continuations end in `>`: bash's bare `>`, zsh's
        # `heredoc>`, `quote>`, `cmdsubst>`, etc. None are idle prompts.
        # Node's REPL also uses `>`, so callers for node keep the default true.
        lastLine = strip(last(split(stripped, '\n')))
        endswith(lastLine, ">") && return false
    end
    any(re -> occursin(re, stripped), _IDLE_PROMPT_RES) && return true
    return any(suffix -> endswith(stripped, suffix),
               _LEGACY_IDLE_PROMPT_SUFFIXES)
end

# Glyph signature of the RAW last line: an uncolored prompt matches here without
# any ANSI scrubbing, which is what the 20 ms poll in `awaitIdlePrompt` pays for
# on every tick. `_tailAtIdlePrompt` remains the ANSI-aware fallback.
const _IDLE_PROMPT_RAW_RE =
    r"(?:julia>|>>>|In \[\d+\]:|In :|\.\.\.\.\.?|[>\]%$#])\s*$"

"""
    promptSegment(sess) :: String

The prompt the REPL is showing RIGHT NOW. Julia redraws prompts with carriage
returns instead of newlines, so the tail's "last line" can hold several prompts
(`julia> \r\r(@v1.13) pkg>`); the live one is the last non-empty `\r`-separated
segment, ANSI-stripped.
"""
function promptSegment(sess::ReplSession)::String
    clean = _stripAnsi(tailLastLine(sess.tail))
    seg = ""
    for part in split(clean, '\r')
        trimmed = strip(part)
        isempty(trimmed) || (seg = String(trimmed))
    end
    return seg
end

"""
    pendingInputLine(sess) :: String

Text typed at the prompt but NOT submitted yet ("" when the input line is empty).
A leftover word keeps the pane out of `atPrompt` (the prompt line is no longer a
bare prompt), so `send` is refused — the agent must know WHAT is sitting there to
clear it (Ctrl-U/Ctrl-C) or submit it (Enter). Observed live: `type q` meant for a
pager landed at the shell, and the agent waited 30 turns at `atPrompt=false`.
"""
function pendingInputLine(sess::ReplSession)::String
    # A SUBMITTED command line is still the last non-empty line until the shell
    # prints its output/prompt. It is not typed-but-pending text: the raw tail
    # already ends in the newline that submitted it. Without this, a shell run
    # read as "pending input", so the monitor never saw a running command.
    ended = lock(sess.tail.lock) do
        # LF, not a bare CR: a line editor redraws with CR while the text is
        # still pending, and treating that as "submitted" would let a send
        # append to a partially typed line.
        !isempty(sess.tail.buf) && sess.tail.buf[end] == 0x0a
    end
    ended && return ""
    # A shell redraws with `\r`: take the LAST carriage-return segment of the last
    # line, or the old prompt text before the redraw reads as "pending input".
    clean = _stripAnsi(tailLastLine(sess.tail))
    line = ""
    for part in split(clean, '\r')
        trimmed = strip(part)
        isempty(trimmed) || (line = String(trimmed))
    end
    # Line editing leaves artifacts in the RAW stream: zsh's Ctrl-U prints the
    # killed text then backspaces over it (`q\b \b`). Apply backspaces so a
    # cleared line reads as empty instead of "pending input".
    buf = Char[]
    for c in line
        if c == '\b' || c == '\x7f'
            isempty(buf) || pop!(buf)
        else
            push!(buf, c)
        end
    end
    line = strip(String(buf))
    isempty(line) && return ""
    # The LAST prompt glyph followed by whitespace starts the input field (julia>,
    # pkg>, help?>, user@host:~%, bash$, node>). Everything after it is typed text.
    pos = 0
    i = firstindex(line)
    while i <= lastindex(line)
        c = line[i]
        j = nextind(line, i)
        if c in ('%', '$', '#', '>') && j <= lastindex(line) && isspace(line[j])
            pos = j
        end
        i = j
    end
    pos == 0 && return ""
    after = strip(line[pos:end])
    # Terminal BOOKKEEPING is not typed input: OSC-133 marks are BEL-terminated,
    # and a pager's exit can leave those BELs after the prompt. The agent's
    # stray-input guard saw `"\a\a"`, cleared it, and the redraw added another
    # BEL — every send was refused forever. Control characters (except Tab)
    # never constitute a pending command line.
    after = strip(String(filter(c -> c == '\t' || !iscntrl(c), after)))
    return after == line || isempty(after) ? "" : after
end

"""
    unterminatedHeredoc(code) -> String | nothing

The terminator a shell heredoc in `code` never receives. A command carrying
`cat <<'EOF'` and a body but losing the final `EOF` (JSON truncation) leaves the
SHELL at `heredoc>` forever: later sends become heredoc lines, not commands, so
the agent gets no feedback and the session looks wedged. Refuse it BEFORE
writing instead of typing half a command.
"""
const _HEREDOC_OPEN_RE = r"<<(-?)[ \t]*(?:'([^']+)'|\"([^\"]+)\"|([A-Za-z_][A-Za-z0-9_.:-]*))"

"Does this shell code open at least one heredoc?"
hasHeredoc(code::AbstractString) = occursin(_HEREDOC_OPEN_RE, String(code))

function unterminatedHeredoc(code::AbstractString)::Union{Nothing,String}
    text = String(code)
    # <<EOF / <<'EOF' / <<-EOF; not <<< (here-string).
    re = _HEREDOC_OPEN_RE
    lines = split(text, '\n')
    for (li, line) in enumerate(lines)
        for m in eachmatch(re, line)
            dash = m.captures[1] == "-"
            delim = something(m.captures[2], m.captures[3], m.captures[4])
            delim === nothing && continue
            found = false
            for j in (li + 1):length(lines)
                body = rstrip(lines[j], '\r')
                dash && (body = lstrip(body, '\t'))
                if body == delim
                    found = true
                    break
                end
            end
            found || return String(delim)
        end
    end
    return nothing
end

"Shell-aware quote balance (double quotes inside single quotes are literal)."
function _shellQuotesBalanced(code::AbstractString)::Bool
    state = :none
    esc = false
    for c in code
        if state === :single
            c == '\'' && (state = :none)
        elseif state === :double
            if esc
                esc = false
            elseif c == '\\'
                esc = true
            elseif c == '"'
                state = :none
            end
        else
            if esc
                esc = false
            elseif c == '\\'
                esc = true
            elseif c == '\''
                state = :single
            elseif c == '"'
                state = :double
            end
        end
    end
    return state === :none
end

"""
    shellIncompleteReason(code) -> String | nothing

Generic preflight for a shell line that would leave the shell at PS2 instead of
executing: an unclosed heredoc, unclosed single/double quote, trailing
backslash/operator, or unclosed subshell. This is not heredoc-specific; heredoc
is simply one way to be incomplete.
"""
function shellIncompleteReason(code::AbstractString)::Union{Nothing,String}
    text = String(code)
    if (delim = unterminatedHeredoc(text)) !== nothing
        return "heredoc delimiter " * repr(delim) * " is missing"
    end
    _shellQuotesBalanced(text) || return "an unclosed quote"
    occursin(r"(?<!\\)\\\s*$", text) && return "a trailing backslash"
    occursin(r"(?:&&|\|\||\|)\s*$", text) && return "a trailing pipe/operator"
    return nothing
end

"Send Ctrl+C after a PS2 wedge and wait briefly for a real prompt."
function _abortPS2!(sess::ReplSession)::Bool
    _stopTimedOutRun!(sess) || return false
    deadline = time() + 2.0
    while time() < deadline
        try
            shellAtPS2(sess) || return true
        catch
        end
        sleep(0.02)
    end
    return false
end

"""
    recoverStuckContinuation!(sess; waitS = 2.0) -> Bool

The agent harness equivalent of a wedged heredoc: a previous send left the
shell at `heredoc>`, `quote>`, `cmdsubst>`… (any PS2). Subsequent sends are
then consumed as body text, so a long-running run burns turns with no output.
When the AGENT owns input, send Ctrl+C, wait for a real prompt, and report
recovery. User-owned input is never touched.
"""
function recoverStuckContinuation!(sess::ReplSession; waitS::Real = 2.0)::Bool
    sess.closed && return false
    sess.altScreen && return false
    try
        currentState(sess.control) == :user && return false
    catch
        return false
    end
    shellAtPS2(sess) || return false
    _stopTimedOutRun!(sess) || return false
    deadline = time() + Float64(waitS)
    while time() < deadline
        idle = try
            _tailAtIdlePrompt(tailText(sess.tail); bare_gt = false)
        catch
            false
        end
        if idle && isempty(pendingInputLine(sess))
            return true
        end
        sleep(0.02)
    end
    return false
end

"A shell session showing a PS2 continuation (line ends with `>`)."
function shellAtPS2(sess::ReplSession)::Bool
    try
        sessionKind(sess) in (:shell, :unknown) &&
            endswith(strip(promptSegment(sess)), ">")
    catch
        false
    end
end

const _ALT_MODE_RE = r"\e\[\?(?:1049|1047|47)([hl])"
const _CURSOR_VIS_RE = r"\e\[\?25([hl])"
# A pager's STATUS TEXT is only live while it is at the END of the stream: after
# the pager exits, the prompt is redrawn BELOW it and the marker stays in history.
const _PAGER_TEXT_RE = r"\(END\)|lines \d+-\d+/\d+|-- (?:More|less)--"
const _PAGER_TEXT_WINDOW = 1200

"""
    _tailLooksLikeApp(tail) :: Bool

True when the pane's raw tail shows a full-screen program (alternate screen, a
hidden cursor, or a pager status line) as its CURRENT state.

The LAST transition of each kind decides. Substring matching over the whole
window was wrong in a costly way: after `micro`/`vim` exited, the tail still held
the `\e[?1049h` that opened it, so every later turn looked like "app-running", the
agent could not `send` (refused) and spun on `type` until the no-progress stop.
`\e[?25l` alone is not a footprint either — shells toggle cursor visibility while
editing a prompt.
"""
function _tailLooksLikeApp(tail::AbstractString)::Bool
    text = last(String(tail), 4096)
    lastAlt = nothing
    for m in eachmatch(_ALT_MODE_RE, text)
        lastAlt = m.captures[1]          # eachmatch is ordered: final wins
    end
    lastAlt == "h" && return true
    lastVis = nothing
    for m in eachmatch(_CURSOR_VIS_RE, text)
        lastVis = m.captures[1]
    end
    lastVis == "l" && return true
    return occursin(_PAGER_TEXT_RE, last(text, _PAGER_TEXT_WINDOW))
end

"""
    replMode(sess::ReplSession) :: Symbol

Which input mode the FOREGROUND REPL is in, read from its last prompt line:
`:julia`, `:help` (`help?>`), `:shell` (`shell>`), `:pkg` (`(@v1.x) pkg>`), or
`:unknown` for a plain shell/generic prompt.

Julia's REPL has MODAL prompts and `send` means something different in each: a
Julia statement at `julia>`, a shell command at `shell>`, a Pkg command at
`pkg>`, a help query at `help?>`. Typing the wrong kind does not fail loudly —
it silently does something else — so the agent has to know the mode, and
completion/error classification has to match it.
"""
function replMode(sess::ReplSession)::Symbol
    line = promptSegment(sess)
    isempty(line) && return :unknown
    occursin(r"help\?>\s*$", line) && return :help
    occursin(r"pkg>\s*$", line) && return :pkg
    occursin(r"shell>\s*$", line) && return :shell
    occursin(r"julia>\s*$", line) && return :julia
    return :unknown
end

"""
    awaitIdlePrompt(sess::ReplSession; timeoutS::Float64 = 10.0) :: Bool

Before every agent write, wait briefly until the visible tail ends with an
idle prompt (`julia>` for REPL sessions, `\$`/`%`/`#`/`>` for shells). This
guarantees the previous evaluation has finished echoing so sentinel output is
never interleaved with a fresh payload. Returns false on timeout so children
with nonstandard prompts are never blocked — delivery then proceeds
best-effort.
"""
function awaitIdlePrompt(sess::ReplSession; timeoutS::Float64 = 2.0)
    t0 = time()
    while time() - t0 < timeoutS
        line = promptSegment(sess)
        shell = try sessionKind(sess) == :shell catch; false end
        ps2 = shell && endswith(strip(line), ">")
        # Fast path: with shell integration flowing, the A/D mark state IS the
        # truth about prompt idleness — except PS2, which emits no C mark.
        _oscAtIdlePrompt(sess) && !ps2 && return true
        (!ps2 &&
         (occursin(_IDLE_PROMPT_RAW_RE, line) ||
          _tailAtIdlePrompt(line; bare_gt = !shell))) && return true
        sleep(0.02)
    end
    return false
end

"""
    sessionKind(sess::ReplSession) :: Symbol

Which payload emitter `agentWriteAndWait` types into the PTY right now:
`:julia`, `:python`, `:node`, or `:shell`. Resolution order:
1. The spawn command (`sess.cmd`) when it names a REPL binary directly.
2. Detected flavor evidence (banner/prompt) captured at boot.
3. FOREGROUND EVIDENCE from the live output tail (generic-terminal model:
"""
function sessionKind(sess::ReplSession)::Symbol
    # OSC-integrated shells are authoritative about being back at a shell prompt:
    # once the spawned application exits, the zsh A/D mark tells us the
    # foreground process is the shell again, even if the tail still shows
    # remnants of a nested REPL's banner.
    if sess.oscSeen && _oscAtIdlePrompt(sess)
        return :shell
    end
    # 1. What we SPAWNED is authoritative for direct sessions.
    occursin(r"\bjulia\b", sess.cmd) && return :julia
    occursin(r"\bipython3?\b|\bpython3?\b", sess.cmd) && return :python
    occursin(r"\bnode\b", sess.cmd) && return :node
    # 2. Boot-time flavor classification.
    if sess.flavor isa ReplFlavor
        sess.flavor == FlootyREPLBridge.replJulia && return :julia
    end
    # 3. Foreground evidence: the LAST LINE of the visible tail decides
    # which interpreter is currently listening.
    stripped = rstrip(_stripAnsi(FlootyPTYLayer.tailText(sess.tail)))
    isempty(stripped) && return :shell
    lastLine = String(strip(last(split(stripped, '\n'))))
    occursin("julia>", lastLine) && return :julia
    occursin(">>>", lastLine) && return :python
    (occursin("In [", lastLine) || occursin("In :", lastLine)) && return :python
    # Node's REPL prompt is EXACTLY `>`; a heredoc/PS2 line like `heredoc>`
    # belongs to the shell and must not flip the session to :node.
    strip(lastLine) == ">" && return :node
    return :shell
end
"""
    shellPayload(code, evalId) :: Vector{UInt8}

Shell-side twin of `agentPayload` (generic-terminal model): type the SAME
sentinel tokens the Julia path emits, but as plain `printf` commands any
POSIX shell executes verbatim. END carries the command's REAL exit status
via `\$?`; pairing/excerpt logic in FlootyREPLBridge parses these tokens
exactly like the Julia-printed ones.

Line discipline: each line is typed separately (zsh/bash echo + execute it
line by line), mirroring the Julia path's line-based delivery. The marker
is embedded as its literal UTF-8 bytes inside single quotes — single
quotes survive both shells uninterpreted — and travels as its OWN printf
argument so the typed line's tty echo never holds marker+tag adjacent:
echo precedes execution, and a complete echoed token would resolve the
eval off the echo and lose the excerpt (the exact failure
agentPayload's programmatic-println form exists to avoid).

Known limitation: commands that CONSUME stdin (`cat`, `read`) swallow the
following printf line — same class of hazard Warp has with hook-less
shells; the watchdog resolves those evals on timeout instead of hanging.
"""
function shellPayload(code::AbstractString, evalId::AbstractString)
    marker = FlootyREPLBridge._SENTINEL_MARKER   # literal UTF-8 bytes of U+F0A7
    body = String(code)
    lines = split(replace(body, "\r\n" => "\n"), '\n')
    io = IOBuffer()
    # Shell metacharacters enter the payload through character literals only:
    # no raw dollar ever reaches Julia's interpolator, and quoting stays flat
    # (single/double quotes are ordinary characters inside Julia strings).
    dollar = '$'
    dquote = '"'
    printfNl = "\\n"              # two chars: backslash + n (a printf newline)
    # Tag split for the same reason as the Julia path: a typed line's echo must
    # never hold the complete token, or a scrubber that blanks the segment
    # carrying it leaves the previous per-keystroke redraw on screen as a
    # truncated wrapper no later chunk can erase.
    tagHead = "FLOOTY_"
    println(io, "printf '%s%s", printfNl, "' '", marker, tagHead, "' '",
            "EVAL_BEGIN:", evalId, "'")
    for ln in lines
        isempty(strip(ln)) || println(io, ln)
    end
    # END reflects the REAL exit status of everything just executed; the
    # bridge additionally flags excerpts containing ERROR: as err.
    print(io, "__flooty_rc=", dollar, "?; printf '%s%s:%s", printfNl, "' '",
          marker, tagHead, "' '", "EVAL_END:", evalId, "' ", dquote, dollar,
          "([ ", dquote, dollar,
          "__flooty_rc", dquote, " -eq 0 ] && echo ok || echo err)",
          dquote, '\n')
    return Vector{UInt8}(codeunits(String(take!(io))))
end

"""
    pythonPayload(code, evalId) :: Vector{UInt8}

Python-side twin of `agentPayload` for CPython AND IPython prompts (both are
listening when the tail ends in `>>>` / `In [n]:`). Typed line by line like
the shell path. END carries the REAL outcome via Python state: `ok` unless
an exception is pending (`sys.last_value` / `sys.last_exc`) or a traceback
was printed — the bridge additionally flags excerpts containing `ERROR:` or
`Traceback`. Blank lines are skipped (they terminate continuation blocks).

Known limitation: `exit()` / `quit()` inside the code leaves the interpreter
before the END printf runs; the watchdog resolves the eval on timeout.
"""
function pythonPayload(code::AbstractString, evalId::AbstractString)
    marker = FlootyREPLBridge._SENTINEL_MARKER   # literal UTF-8 bytes of U+F0A7
    body = String(code)
    lines = split(replace(body, "\r\n" => "\n"), '\n')
    io = IOBuffer()
    println(io, "import sys as _fl_sys")
    # Tag split (see agentPayload): the echoed source must never hold the
    # complete token, only the child's PRINTED marker line may — that one is a
    # whole line and blanks cleanly.
    println(io, "print('", marker, "FLOOTY_', 'EVAL_BEGIN:", evalId,
            "', sep='', flush=True)")
    for ln in lines
        isempty(strip(ln)) || println(io, ln)
    end
    # ok unless an exception is pending; works back to Python 3.7.
    print(io,
          "_fl_ok = 'no' if getattr(_fl_sys, 'last_exc', None) is not None " *
          "or getattr(_fl_sys, 'last_value', None) is not None else 'yes'; ")
    println(io, "print('", marker, "FLOOTY_', 'EVAL_END:", evalId,
            "', _fl_ok, sep='', end='\\n', flush=True)")
    return Vector{UInt8}(codeunits(String(take!(io))))
end

"""
    nodePayload(code, evalId) :: Vector{UInt8}

Node-side twin of `agentPayload`: same tokens, typed line by line into the
node REPL. END reflects the real outcome via node's error state — `err`
when `_error` is set (uncaught exception at the prompt), `ok` otherwise.
The bridge additionally flags excerpts containing `ERROR:` / `Traceback`.

Known limitation: `.exit` / process.exit() inside the code skips the END
console.log; the watchdog resolves the eval on timeout.
"""
function nodePayload(code::AbstractString, evalId::AbstractString)
    marker = FlootyREPLBridge._SENTINEL_MARKER   # literal UTF-8 bytes of U+F0A7
    body = String(code)
    lines = split(replace(body, "\r\n" => "\n"), '\n')
    io = IOBuffer()
    println(io, "console.log('", marker, "FLOOTY_' + 'EVAL_BEGIN:", evalId, "')")
    for ln in lines
        isempty(strip(ln)) || println(io, ln)
    end
    print(io, "console.log('", marker, "FLOOTY_' + 'EVAL_END:", evalId,
          "' + (typeof _error !== 'undefined' && _error ? ':err' : ':ok'))")
    write(io, 0x0a)
    return Vector{UInt8}(codeunits(String(take!(io))))
end

# Payload flavours: which emitter wraps `code` for the interpreter currently in
# the foreground. Dispatched on a concrete flavour type instead of a ternary on
# `sessionKind`'s symbol.
abstract type ReplFlavorKind end
struct ShellFlavor  <: ReplFlavorKind end
struct PythonFlavor <: ReplFlavorKind end
struct NodeFlavor   <: ReplFlavorKind end
struct JuliaFlavor  <: ReplFlavorKind end

"Map `sessionKind`'s symbol to its payload flavour (anything but the three
non-Julia interpreters is a Julia session)."
flavorKind(kind::Symbol)::ReplFlavorKind =
    kind === :shell ? ShellFlavor() :
    kind === :python ? PythonFlavor() :
    kind === :node ? NodeFlavor() : JuliaFlavor()

"Wrap `code` in the sentinel payload `flavor`'s interpreter understands."
evalPayload(::ShellFlavor, code, evalId)  = shellPayload(code, evalId)
evalPayload(::PythonFlavor, code, evalId) = pythonPayload(code, evalId)
evalPayload(::NodeFlavor, code, evalId)   = nodePayload(code, evalId)
evalPayload(::JuliaFlavor, code, evalId)  =
    Vector{UInt8}(codeunits(agentPayload(code, evalId)))

const INTERACTIVE_SESSION_COMMANDS = Set([
    "ssh", "mosh", "telnet", "sftp", "ftp", "nc", "ncat",
    "vim", "nvim", "vi", "nano", "emacs", "micro",
    "less", "more", "man", "top", "htop", "btop", "tmux", "screen",
    # full-screen TUIs that own the keyboard: a sentinel wrapper typed into one
    # is read as KEYSTROKES (the broot report).
    "broot", "ranger", "nnn", "lf", "vifm", "mc", "fzf", "lazygit", "gitui",
    "tig", "ncdu", "glances", "nvtop", "alsamixer", "cmus", "ncmpcpp", "k9s",
    "mutt", "neomutt", "irssi", "weechat", "dialog", "whiptail",
    # PAGERS: they take over the screen and wait for keys. `bat`/`batcat` are
    # pagers unless told otherwise, which is why `send "bat file"` used to sit
    # until the eval timeout — the prompt cannot come back while the pager runs.
    "bat", "batcat", "most", "pg", "lesspipe",
])
const SHELL_COMMANDS = Set(["bash", "sh", "zsh", "fish", "dash", "ksh"])
const INTERPRETER_COMMANDS = Set([
    "python", "python3", "ipython", "ipython3", "julia", "node", "deno",
    "irb", "ghci", "R", "psql", "mysql", "sqlite3", "redis-cli",
])
const NON_INTERACTIVE_INTERPRETER_FLAGS = ("-c", "-e", "--eval", "-m", "-p",
                                          "-v", "--version", "-V")

"""
    isInteractiveCommand(code) :: Bool

Commands that take over the foreground and DO NOT RETURN until the user quits
them — `ssh host` above all. No END sentinel can arrive while one runs, so
`agentWriteAndWait` must not block on one: the agent needs "started" back so it
can keep working INSIDE the new session (typing the next command there, or
waiting on the pane).

Classification is deliberately narrow and boring: the first word (after env
assignment prefixes), with the flags that make a launcher non-interactive
(`bash -c`, `python -c/-m`, `tail -f` vs `tail -n`, `docker exec -it` vs
`docker ps`) checked explicitly.
"""

"Positional arguments of an ssh-style command line (flags + their values skipped)."
const SSH_VALUE_FLAGS = Set(["-p", "-i", "-l", "-o", "-F", "-E", "-J", "-b", "-c",
                             "-m", "-O", "-Q", "-R", "-S", "-W", "-w", "-L", "-D",
                             "--port", "--identity", "--login", "--option"])
function _positionalArgs(args)
    out = String[]
    i = 1
    while i <= length(args)
        w = String(args[i])
        if startswith(w, "-")
            i += w in SSH_VALUE_FLAGS ? 2 : 1
            continue
        end
        push!(out, w)
        i += 1
    end
    return out
end

function isInteractiveCommand(code::AbstractString)::Bool
    s = strip(String(code))
    isempty(s) && return false
    # Julia REPL pagers: TerminalPager.pager(...) blocks the REPL until q.
    # It is not a shell word, so classify it here (the `send` path otherwise
    # wraps it in sentinels and burns the whole timeout).
    (occursin("TerminalPager", s) || occursin(r"\bpager\s*\(", s)) && return true
    words = split(s, r"[ \t]+")
    i = 1
    while i <= length(words) && occursin(r"^[A-Za-z_][A-Za-z0-9_]*=", words[i])
        i += 1
    end
    i <= length(words) || return false
    cmd = basename(String(words[i]))
    args = i < length(words) ? words[(i + 1):end] : String[]
    has(pred) = any(pred, args)
    # `ssh host` opens a session (interactive); `ssh host "cmd"` runs a remote
    # one-shot and RETURNS — waiting for its output keeps the real exit status.
    if cmd in ("ssh", "mosh")
        return length(_positionalArgs(args)) <= 1
    end
    cmd == "sudo" && return has(w -> w in ("-i", "--login", "-s", "--shell"))
    cmd == "su" && return true
    (cmd in ("docker", "podman", "kubectl")) &&
        return has(w -> w in ("-i", "-it", "-ti", "--interactive"))
    # `tail -f` follows forever; `tail -n 5 file` returns. `watch` runs until
    # interrupted unless it got an explicit count.
    cmd == "tail" &&
        return has(w -> w == "-f" || startswith(w, "-f") || w == "--follow")
    cmd == "watch" && return true
    # `bat --paging=never` is a plain filter: it returns, so it is NOT interactive.
    (cmd in ("bat", "batcat")) &&
        return !any(w -> w == "--paging=never" || startswith(w, "--paging=never"), args)
    (cmd in ("nc", "ncat")) && return !has(w -> w == "-z")
    (cmd in SHELL_COMMANDS) && return !has(w -> w == "-c")
    (cmd in INTERPRETER_COMMANDS) &&
        return !has(w -> w in NON_INTERACTIVE_INTERPRETER_FLAGS)
    return cmd in INTERACTIVE_SESSION_COMMANDS
end

"""
    agentWriteAndWait(sess::ReplSession, code::AbstractString;
                      timeout::Float64=60.0) :: EvalOutcome

The core duplex loop: gate on control state → generate eval id → wrap `code`
with BEGIN/END sentinels emitted per `sessionKind` (Julia println, shell
printf, python print, or node console.log) → write through the PTY →
block until the END sentinel arrives (or watchdog timeout / session close)
→ resolve into the registry → return
`EvalOutcome`. A watchdog timeout yields outcome with `ok=false`,
`errorKind=:incompleteInput` and a diagnostic excerpt.

INTERACTIVE commands (`isInteractiveCommand`, e.g. `ssh host`) cannot produce an
END sentinel while they run: they are typed plain and resolved as soon as the
program shows evidence of starting, with `ok=true, errorKind=:running` and the
first output as the excerpt. `interactive` overrides the classification.
"""

"Call the driver's monitor poll; true means the monitor requested an interrupt."
function _monitorPollInterrupt(poll)
    poll === nothing && return false
    try
        return poll() === :interrupt
    catch
        return false
    end
end

"Stop an agent-owned command that exceeded its eval timeout (never user work)."
function _stopTimedOutRun!(sess::ReplSession)::Bool
    currentState(sess.control) == :user && return false
    try
        writeToPty(sess.pty, Vector{UInt8}(codeunits("\x03")); source = :agent)
        return true
    catch
        return false
    end
end

function agentWriteAndWait(sess::ReplSession, code::AbstractString;
                           timeout::Float64 = DEFAULT_EVAL_TIMEOUT_S,
                           interactive::Union{Nothing,Bool} = nothing,
                           startupS::Real = 8.0,
                           poll::Union{Nothing,Function} = nothing)
    canAgentWrite(sess.control) ||
        error("agentWriteAndWait: agent may not write while control state is :user " *
              "(use tagIn first) or call userWrite for human input")
    sess.pty.open || error("agentWriteAndWait: pty is closed")
    # Generic shell completeness preflight. This covers heredocs, quotes,
    # trailing operators and subshells — every command shape that would leave
    # the shell waiting at PS2 instead of executing.
    if sessionKind(sess) in (:shell, :unknown) &&
       (why = shellIncompleteReason(code)) !== nothing
        id = lock(sess.lock) do
            n = length(sess.registry.history) + length(sess.registry.pending) + 1
            eid = evalIdFor(n)
            trackPendingEval!(sess, eid)
            eid
        end
        outcome = EvalOutcome(evalId = id, ok = false,
            excerpt = "send refused: the command has " * why *
                      "; nothing was typed. Send a complete command, or use " *
                      "{\"action\":\"type\"} for interactive/multiline input.",
            errorKind = :incompleteInput, duration = 0.0)
        resolveEval!(sess.registry, id, outcome)
        lock(sess.lock) do
            delete!(sess.pending, id)
        end
        return outcome
    end
    # REPL MODE SWITCH: Julia's REPL switches mode on a BARE keystroke (`;` shell,
    # `]` pkg, `?` help, backspace back to julia>). A `send` of exactly that
    # character must type it RAW (no Enter — an Enter also submits an empty
    # command) and resolve when the PROMPT CHANGED, not when "the prompt came
    # back": the prompt never left, it changed shape, so a prompt-return wait
    # burns the whole timeout (the "send ] hung at running" report).
    modeKey = strip(String(code))
    if sessionKind(sess) == :julia && !sess.altScreen &&
       (modeKey in (";", "]", "?") || modeKey == "\x7f")
        id = lock(sess.lock) do
            n = length(sess.registry.history) + length(sess.registry.pending) + 1
            eid = evalIdFor(n)
            trackPendingEval!(sess, eid)
            eid
        end
        # The PROMPT LINE is the signal, not `replMode`: pkg has its own
        # sub-prompts (a `;` inside pkg is a shell sub-mode), and a mode name can
        # stay :unknown while the prompt demonstrably changed.
        before = promptSegment(sess)
        # Backspace at `julia>` is a no-op: answer immediately instead of waiting
        # out the switch timeout.
        if modeKey == "\x7f" && replMode(sess) == :julia
            outcome = EvalOutcome(evalId = id, ok = false,
                                  excerpt = "already at julia>; backspace does nothing",
                                  errorKind = :none, duration = 0.0)
            resolveEval!(sess.registry, id, outcome)
            lock(sess.lock) do
                delete!(sess.pending, id)
            end
            return outcome
        end
        t0 = time()
        writeToPty(sess.pty, Vector{UInt8}(codeunits(String(code))); source = :agent)
        deadline = t0 + min(Float64(timeout), 5.0)
        after = before
        switched = false
        while time() < deadline
            after = promptSegment(sess)
            # A mode key CHANGES the prompt (possibly into a sub-prompt like
            # pkg's help `?`); requiring the new prompt to be a known idle one
            # made those switches hang for the full timeout.
            if after != before && !isempty(after)
                switched = true
                break
            end
            sleep(0.02)
        end
        outcome = EvalOutcome(evalId = id, ok = switched,
                              excerpt = switched ?
                                  "repl mode switched: " * repr(before) * " -> " * repr(after) :
                                  "repl mode unchanged (" * repr(before) * "); keys=" *
                                  repr(modeKey),
                              errorKind = switched ? :none : :incompleteInput,
                              duration = time() - t0)
        resolveEval!(sess.registry, id, outcome)
        lock(sess.lock) do
            delete!(sess.pending, id)
        end
        return outcome
    end


    # A full-screen TUI has no prompt to wait for: skip the gate (it would burn
    # the whole timeout on every keystroke we send into it).
    if !sess.altScreen &&
       !(awaitIdlePrompt(sess) && isempty(pendingInputLine(sess)))
        # Heredoc-like wedge: if the agent owns this shell and it is sitting at
        # PS2, abort that incomplete continuation deterministically instead of
        # letting a long run pile every later send into the heredoc body.
        recoverStuckContinuation!(sess)
    end
    if !sess.altScreen &&
       !(awaitIdlePrompt(sess) && isempty(pendingInputLine(sess)))
        # Do NOT type blind when the prompt never became idle (pager, password
        # prompt, SSH auth, a stale snapshot). The caller sees an explicit
        # failure instead of a command silently landing in the wrong program.
        id = lock(sess.lock) do
            n = length(sess.registry.history) + length(sess.registry.pending) + 1
            eid = evalIdFor(n)
            trackPendingEval!(sess, eid)
            eid
        end
        outcome = EvalOutcome(evalId = id, ok = false,
            excerpt = "not at an idle prompt; command not sent (screen may be " *
                      "a pager/editor/auth prompt, or input is busy)",
            errorKind = :incompleteInput, duration = 0.0)
        resolveEval!(sess.registry, id, outcome)
        lock(sess.lock) do
            delete!(sess.pending, id)
        end
        return outcome
    end

    # Which KIND of command is this? Interactive foreground programs (ssh, vim, a
    # nested shell) never return, so no END sentinel can arrive: they take their
    # own path below, and everything after this point is the sentinel/native path.
    interactive === nothing &&
        (interactive = isInteractiveCommand(code) || sess.altScreen)

    # INTERACTIVE FOREGROUND (ssh, vim, a nested shell …): the command does not
    # return, so no END sentinel can arrive and waiting for one would burn the
    # whole eval timeout and report a spurious failure ("ssh … runs forever").
    # Type it PLAIN, wait only for evidence that it started, and report
    # `:running` so the loop continues inside the new session.
    if interactive
        id = lock(sess.lock) do
            n = length(sess.registry.history) + length(sess.registry.pending) + 1
            eid = evalIdFor(n)
            trackPendingEval!(sess, eid)
            eid
        end
        before = tailEnd(sess.tail)
        t0 = time()
        writeToPty(sess.pty, Vector{UInt8}(codeunits(string(rstrip(String(code)), '\n')));
                   source = :agent)
        deadline = t0 + min(Float64(timeout), Float64(startupS))
        started = false
        interrupted = false
        lastPoll = t0
        while time() < deadline
            if tailEnd(sess.tail) > before
                started = true
                break
            end
            if time() - lastPoll >= 0.1
                lastPoll = time()
                if _monitorPollInterrupt(poll)
                    interrupted = true
                    _stopTimedOutRun!(sess)
                    break
                end
            end
            sleep(0.02)
        end
        sleep(0.15)     # let the first frame / prompt land before we read it
        seen = strip(tailTextFrom(sess.tail, before))
        excerpt = started && !isempty(seen) ? seen :
                  "[started interactive command; no output yet]"
        interrupted &&
            (excerpt *= "\n[monitor interrupt: Ctrl+C sent]")
        outcome = EvalOutcome(evalId = id, ok = !interrupted, excerpt = excerpt,
                              errorKind = interrupted ? :incompleteInput : :running,
                              duration = time() - t0)
        resolveEval!(sess.registry, id, outcome)
        lock(sess.lock) do
            delete!(sess.pending, id)
        end
        return outcome
    end

    # PROMPT-WATCH: no OSC 133 integration (a Linux box over ssh, a plain bash),
    # but the shell WAS at a prompt we recognize before the write. Watch for that
    # prompt to come BACK instead of typing a BEGIN/END wrapper — the wrapper's
    # echo is what the user sees in the pane ("__flooty_rc=$?; printf …").
    # Cost: the shell's exit status is gone, so failure comes from the output
    # (`classifyShellError`); a command whose text looks clean reports ok without
    # a verified exit code. Wrapper mode remains the fallback for prompts we
    # cannot recognize (and for the REPL flavors).
    kindBefore = sessionKind(sess)
    # Native OSC completion is unreliable for heredocs: some shells never emit
    # the closing D mark until after the body, and a sentinel cannot be inside
    # the heredoc. Force the prompt-return watcher for them.
    nativePossible = sess.oscSeen && kindBefore == :shell &&
        _oscAtIdlePrompt(sess) && !shellAtPS2(sess) &&
        !hasHeredoc(code) && !occursin('\n', code)
    # Any recognisable idle prompt (julia>, >>>, >, %/$/#) can be watched for its
    # RETURN: that is the completion signal, and unlike the shell case it costs
    # nothing for Julia — an incomplete input never gets its prompt back anyway,
    # exactly like today's timeout path.
    # The LIVE prompt segment decides (not the raw last line: after a pager quits,
    # leftover redraw text can share the line with the prompt).
    promptWatch = !nativePossible &&
        _tailAtIdlePrompt(promptSegment(sess); bare_gt = kindBefore != :shell)
    if promptWatch
        id = lock(sess.lock) do
            n = length(sess.registry.history) + length(sess.registry.pending) + 1
            eid = evalIdFor(n)
            trackPendingEval!(sess, eid)
            eid
        end
        before = tailEnd(sess.tail)
        t0 = time()
        writeToPty(sess.pty, Vector{UInt8}(codeunits(string(rstrip(String(code)), '\n')));
                   source = :agent)
        quietSince = time()
        lastEnd = before
        finished = false
        interrupted = false
        lastPoll = t0
        ps2Since = 0.0
        while time() - t0 < Float64(timeout)
            now = tailEnd(sess.tail)
            if now > lastEnd
                lastEnd = now
                quietSince = time()
            elseif now > before && (time() - quietSince) >= PROMPT_QUIET_S &&
                   _tailAtIdlePrompt(promptSegment(sess);
                                     bare_gt = kindBefore != :shell)
                finished = true
                break
            end
            # A heredoc/quote that never closes otherwise burns the full eval
            # timeout and leaves the UI's send block "running" even after the
            # user presses Ctrl+C. Abort it ourselves.
            ps2Now = try shellAtPS2(sess) catch; false end
            if ps2Now
                ps2Since == 0.0 && (ps2Since = time())
                if time() - ps2Since >= 2.0
                    _abortPS2!(sess)
                    interrupted = true
                    break
                end
            else
                ps2Since = 0.0
            end
            if time() - lastPoll >= 0.1
                lastPoll = time()
                if _monitorPollInterrupt(poll)
                    interrupted = true
                    _stopTimedOutRun!(sess)
                    break
                end
            end
            sleep(0.02)
        end
        excerpt = strip(tailTextFrom(sess.tail, before))
        if interrupted
            excerpt *= "\n[monitor interrupt: Ctrl+C sent]"
        elseif !finished
            killed = _stopTimedOutRun!(sess)
            excerpt *= killed ?
                "\n[timeout: Ctrl+C sent to stop the command]" :
                "\n[timeout: command may still be running; user owns the pane]"
        end
        modeNow = replMode(sess)
        errorKind = if !finished
            :incompleteInput
        else
            # Classification follows the MODE the line ran in: a shell line's
            # failures look like `command not found`, a Julia/Pkg/help line's like
            # `ERROR:`/`MethodError`. Prompt-watch has no exit status to fall back
            # on, so the other classifier is the fallback for each.
            k = modeNow == :shell ? classifyShellError(excerpt) : classifyError(excerpt)
            if k == :none
                k = modeNow == :shell ? classifyError(excerpt) : classifyShellError(excerpt)
            end
            k
        end
        ok = finished && errorKind == :none
        outcome = EvalOutcome(evalId = id, ok = ok, excerpt = excerpt,
                              errorKind = errorKind, duration = time() - t0)
        resolveEval!(sess.registry, id, outcome)
        lock(sess.lock) do
            delete!(sess.pending, id)
        end
        return outcome
    end

    # Line-based delivery: the BEGIN/END sentinels pair on tokens appearing in
    # the OUTPUT stream, so chunking never breaks eval resolution.
    # (Bracketed-paste wrapping was tried and dropped: the stdlib paste handler
    # readuntil-races the PTY byte stream.) The WRAPPER is flavor-specific —
    # Julia println(), plain printf, python print(), node console.log() —
    # but the tokens themselves are identical, so everything downstream is
    # flavor-blind.
    id = lock(sess.lock) do
        n = length(sess.registry.history) + length(sess.registry.pending) + 1
        eid = evalIdFor(n)
        trackPendingEval!(sess, eid)
        eid
    end
    local payload::Vector{UInt8}
    kindNow = sessionKind(sess)
    # NATIVE dispatch needs the INTEGRATED shell to be at a MARKED prompt right
    # now — `oscSeen` alone is a sticky historical flag. A nested foreground
    # process (ssh into another box, `bash`, `docker exec`, a REPL) inherits it
    # but emits no OSC 133 C/D marks, so a plain payload can never be resolved:
    # the shell reports C when the nested program starts and D only when it
    # exits, leaving `pendingOpen` set for the whole nested session. That is the
    # "commands fail on the remote/Linux box" failure: every write timed out as
    # `incompleteInput`. Sentinels work in ANY POSIX shell, so the fallback is
    # the honest choice while `pendingOpen` says a command is still running.
    native = sess.oscSeen && kindNow == :shell &&
        _oscAtIdlePrompt(sess) && !shellAtPS2(sess)
    if native
        body = string(rstrip(String(code)), '\n')
        payload = Vector{UInt8}(codeunits(body))
    else
        payload = evalPayload(flavorKind(kindNow), code, id)
    end
    t0 = time()
    writeToPty(sess.pty, payload; source = :agent)

    pe = lock(sess.lock) do
        sess.pending[id]
    end
    # Base `wait(::Condition)` has no timeout form; poll `pe.done` instead.
    # The reader task's notify makes wakeups near-instant; 10ms poll latency
    # is negligible next to real eval durations.
    timedOut = false
    interrupted = false
    lastPoll = t0
    ps2Since = 0.0
    while !pe.done
        time() - t0 >= timeout && (timedOut = true; break)
        # A quote/heredoc sent through the sentinel path can sit at PS2 with no
        # completion token. Abort it instead of leaving the UI's send block
        # "running" for the full timeout.
        ps2Now = try shellAtPS2(sess) catch; false end
        if ps2Now
            ps2Since == 0.0 && (ps2Since = time())
            if time() - ps2Since >= 2.0
                _abortPS2!(sess)
                interrupted = true
                break
            end
        else
            ps2Since = 0.0
        end
        if time() - lastPoll >= 0.1
            lastPoll = time()
            if _monitorPollInterrupt(poll)
                interrupted = true
                _stopTimedOutRun!(sess)
                break
            end
        end
        sleep(0.01)
    end

    local outcome::EvalOutcome
    if pe.done
        o = pe.outcome
        outcome = EvalOutcome(evalId = id, ok = o.ok, excerpt = o.excerpt,
                              errorKind = o.errorKind, duration = time() - t0)
    else
        timedOut = true
        timed = interrupted ? "[monitor interrupt: Ctrl+C sent]" :
                (killed = _stopTimedOutRun!(sess);
                 killed ? "\n[timeout: Ctrl+C sent to stop the command]" :
                          "\n[timeout: command may still be running; user owns the pane]")
        excerptEnd = first(tailText(sess.tail), 2048) * "\n" * timed
        outcome = EvalOutcome(evalId = id, ok = false, excerpt = excerptEnd,
                              errorKind = :incompleteInput, duration = time() - t0)
        @debug "agentWriteAndWait: timed out" evalId = id timeoutS = timeout
    end

    resolveEval!(sess.registry, id, outcome)
    lock(sess.lock) do
        delete!(sess.pending, id)
    end
    return outcome
end

"""Recent eval outcomes, newest first (delegates to FlootyREPLBridge)."""
sessionHistory(sess::ReplSession; n::Int = 20) = recentHistory(sess.registry; n)

"""Markdown lines summarizing recent eval outcomes for the sidecar file."""
function statusLines(sess::ReplSession)
    io = IOBuffer()
    println(io, "# REPL status sidecar")
    println(io)
    println(io, "- pid: ", sess.pty.pid)
    println(io, "- controlState: ", currentState(sess.control))
    println(io, "- pendingEvals: ", lock(() -> length(sess.pending), sess.lock))
    hist = sessionHistory(sess; n = 10)
    println(io, "- lastOutcome: ", isempty(hist) ? "(none)" :
                  let h = hist[1]
                      "$(h.errorKind) ($(h.ok ? "ok" : "err")) $(round(h.duration; digits=3))s"
                  end)
    println(io)
    println(io, "| eval | result | kind | duration(s) |")
    println(io, "|---|---|---|---|")
    for h in hist
        println(io, "| ", h.evalId, " | ", h.ok ? "ok" : "err", " | ",
                h.errorKind, " | ", round(h.duration; digits = 3), " |")
    end
    return String(take!(io))
end

"""
    writeStatusSidecar!(sess::ReplSession;
                        path::AbstractString=sess.sidecarPath) :: String

Persist current session status (recent history, control state, pending count)
to the markdown sidecar so other tooling/agents can read cross-run state.
"""
function writeStatusSidecar!(sess::ReplSession;
                             path::AbstractString = sess.sidecarPath)
    mkpath(dirname(abspath(path)))
    text = statusLines(sess)
    open(abspath(path), "w") do f
        write(f, text)
    end
    return abspath(path)
end

"""Close the session: stop the tailer, then tear down the PTY (idempotent)."""
function closeSession!(sess::ReplSession)
    sess.closed && return sess
    sess.closed = true
    empty!(sess.outputTaps)   # drop UI taps so closePty!'s EOF is a clean stop
    closePty!(sess.pty)
    if sess.readerTask !== nothing && !istaskdone(sess.readerTask)
        # closePty! should unblock the reader; bound teardown so a stuck stream
        # cannot hang the app/window close.
        deadline = time() + 2.0
        while !istaskdone(sess.readerTask) && time() < deadline
            sleep(0.05)
        end
        if !istaskdone(sess.readerTask)
            @warn "closeSession!: reader task did not stop within 2s; abandoning it"
        else
            try wait(sess.readerTask) catch end
        end
    end
    return sess
end
