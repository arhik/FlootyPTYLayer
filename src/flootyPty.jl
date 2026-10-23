# flootyPty.jl — owned by pty-layer child agent.
# macOS PTY transport: spawn a subprocess attached to a pseudo-terminal,
# streaming read loop, tagged writes, resize/close.
# Port of FlootyPTY_v2's ATTACHED-spawn semantics (openpty → setsid →
# controlling tty → dup2(slave→0/1/2) → exec) — but NOT via raw fork().
# Verified experimentally (test/debugForkMin.jl): on Darwin, fork() out of a
# running Julia VM produces a child that dies instantly (libuv kqueue
# assertion + ObjC "+initialize after fork" abort) because Julia is
# multithreaded. We therefore posix_spawn a tiny C helper
# (deps/flootySpawnHelper.c) whose whole job is setsid / open(slave) /
# dup2 / execvp — full attachment with no forked-Julia state.
#
# Platform notes (Darwin constants differ from Linux):
#   TIOCSWINSZ = 0x80087467 (set), TIOCGWINSZ = 0x40087468 (get).
#   TIOCSCTTY  = 0x20007461 on macOS (0x540E is the Linux value used by v2).
#   O_NONBLOCK = 0x0004, EAGAIN = 35, EINTR = 4, ECHILD = 10.
#
# ABI WARNING: ioctl(2) is VARIADIC. On arm64 Darwin variadic args must be
# passed on the stack, but Julia's ccall passes them in registers, so every
# ccall(:ioctl, ...) here silently no-ops (rc=0, buffers untouched) — even
# nonsense requests "succeed". All tty ioctls therefore go through the
# non-variadic C wrappers in deps/flootyShim.c, built+loaded at import time.

"""Handle to a PTY-backed subprocess. Fields are owned by this file."""
mutable struct PtyHandle
    id::UUID
    masterFd::Cint
    pid::Int32
    outputCh::Channel{Vector{UInt8}}
    writeLock::ReentrantLock
    readTask::Union{Task,Nothing}
    open::Bool
    exitStatus::Union{Nothing,Int}
    # True when the reader thread waits for readability with poll() instead of
    # polling a non-blocking fd (see masterReadLoop).
    blockingReader::Bool
end

function spawnPty end
function writeToPty end
function outputChannel end
function resizePty! end
function closePty! end

# ---- POSIX constants --------------------------------------------------------

const F_GETFL_FLAG = Cint(3)
const F_SETFL_FLAG = Cint(4)
const O_NONBLOCK_FLAG = Cint(0x0004)                 # Darwin/Linux agree
# Darwin values verified against <sys/ioctl.h> via a compiled probe:
# TIOCSWINSZ = _IOW('t', 103, struct winsize) = 0x80087467
# TIOCGWINSZ = _IOR('t', 104, struct winsize) = 0x40087468
# Linux uses the classic 0x5414 / 0x5413 pair.
const TIOCSWINSZ_IOCTL = Culong(Sys.isapple() ? 0x80087467 : 0x5414)

# ---- posix_spawn configuration ----------------------------------------------
# Flag values shared by Darwin <sys/spawn.h> and glibc >= 2.29:
const POSIX_SPAWN_SETSIGDEF_FLAG = Culong(0x04)
const POSIX_SPAWN_SETSIGMASK_FLAG = Culong(0x08)
const POSIX_SPAWN_SETSID_FLAG = Culong(0x0400)           # enabled on Darwin only
# Verified empirically (test/spawnProbe.jl): 0x1000 makes posix_spawnp fail
# with ENOEXEC(88); the real POSIX_SPAWN_CLOEXEC_DEFAULT bit is 0x4000.
const POSIX_SPAWN_CLOEXEC_DEFAULT_FLAG = Culong(0x4000)  # Darwin-only extension
const SIGTSTP_SIGNAL = Cint(Sys.isapple() ? 18 : 20)     # only TSTP differs BSD/Linux
const SIGTTIN_SIGNAL = Cint(21)
const SIGTTOU_SIGNAL = Cint(22)
const SIGSET_BUF_BYTES = 128                             # >= sizeof(sigset_t) everywhere
const SPAWN_OBJ_BUF_BYTES = 512                          # >= sizeof(posix_spawn*_t)
const EINTR_ERRNO = Cint(4)
const ECHILD_ERRNO = Cint(10)
const EAGAIN_ERRNO = Cint(35)                        # Darwin EAGAIN/EWOULDBLOCK
const SIGTERM_SIGNAL = Cint(15)
const SIGKILL_SIGNAL = Cint(9)
const READ_BUFFER_BYTES = 8192
const READ_POLL_SECONDS = 0.005
# Adaptive poll: the floor applies while output is flowing (the macOS tty
# output queue is 1 KiB, so the poll interval IS the throughput), the ceiling
# is the idle backoff.
const READ_POLL_MIN_SECONDS = 0.0002
const READ_POLL_MAX_SECONDS = 0.005
# Reads are coalesced into batches of this size before they enter the output
# channel (a blocking read returns whatever the kernel has — often a few bytes).
const READ_BATCH_BYTES = 16 * 1024
# How long the reader waits for the REST of a burst before handing it over.
# The macOS tty output queue is 1 KiB, so a full-screen redraw (broot, micro)
# arrives as a dozen short reads; without this window the page paints the
# screen band by band (a raster scan).
const READ_COALESCE_SECONDS = 0.002
# Grace window during which a DATA-LESS EOF (read(master) == 0) is treated as
# the Darwin spawn race below rather than a real hangup. Real EOF after any
# output still terminates the loop immediately.
const SPAWN_EOF_GRACE_SECONDS = 2.0
# How long the PARENT keeps its slave fd open after posix_spawnp returns.
# Mirrors Warp's terminal (app/src/terminal/local_tty/unix.rs): "keep it
# alive long enough" — the helper must open(slavePath) before ANY slave fd
# would otherwise exist, and in that window read(master) returns EOF-shaped 0.
const SLAVE_HOLD_SECONDS = 0.5

# ---- compiled C shim (variadic-ioctl workaround) ----------------------------
# NOTE: ccall is used in (:sym, path) form so no Libdl import is needed
# (Julia 1.12 forbids undeclared stdlib deps; declaring Libdl is unresolvable).
# ccall dlopens+caches the path on first use, covering the forked-child branch.
const SHIM_DIR = normpath(@__DIR__, "..", "deps")
const SHIM_SRC = joinpath(SHIM_DIR, "flootyShim.c")
const SHIM_DLEXT = Sys.isapple() ? "dylib" : Sys.iswindows() ? "dll" : "so"
const SHIM_LIB = joinpath(SHIM_DIR, "libflootyShim.$SHIM_DLEXT")
const HELPER_SRC = joinpath(SHIM_DIR, "flootySpawnHelper.c")
const HELPER_EXE = joinpath(SHIM_DIR,
                            Sys.iswindows() ? "flootySpawnHelper.exe" : "flootySpawnHelper")

"""Compile the C shim and spawn helper once; skips rebuild when up to date."""
function buildFlootyShim!()
    isdir(SHIM_DIR) || mkpath(SHIM_DIR)
    if !isfile(SHIM_LIB) || mtime(SHIM_SRC) > mtime(SHIM_LIB)
        sharedFlag = Sys.isapple() ? "-dynamiclib" : "-shared"
        run(`cc -O2 -fPIC $sharedFlag -o $SHIM_LIB $SHIM_SRC`)
        @info "FlootyPTYLayer: built C shim" SHIM_LIB
    end
    if !Sys.iswindows() &&
       (!isfile(HELPER_EXE) || mtime(HELPER_SRC) > mtime(HELPER_EXE))
        run(`cc -O2 -o $HELPER_EXE $HELPER_SRC`)
        @info "FlootyPTYLayer: built spawn helper" HELPER_EXE
    end
    return SHIM_LIB
end

buildFlootyShim!()

"""Mirror of the BSD `struct winsize` passed to the TIOCSWINSZ ioctl."""
mutable struct Winsize
    wsRow::Cushort
    wsCol::Cushort
    wsXpixel::Cushort
    wsYpixel::Cushort
end
Winsize(rows::Integer, cols::Integer) =
    Winsize(Cushort(rows), Cushort(cols), Cushort(0), Cushort(0))

# ---- low-level helpers ------------------------------------------------------

"""Create a PTY master/slave fd pair via libc openpty(); returns (masterFd, slaveFd)."""
function createPtyPair()
    master = Ref{Cint}(-1)
    slave = Ref{Cint}(-1)
    rc = ccall((:openpty, "libc"), Cint,
               (Ref{Cint}, Ref{Cint}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
               master, slave, C_NULL, C_NULL, C_NULL)
    rc == 0 || error("openpty failed: $(Libc.strerror(Libc.errno()))")
    return (master[], slave[])
end

"""Pack/unpack Winsize through an 8-byte isbits buffer for ccall marshaling."""
winsizeTuple(ws::Winsize) =
    (Cushort(ws.wsRow), Cushort(ws.wsCol), Cushort(0), Cushort(0))

winsizeFrom(buf::NTuple{4,Cushort}) =
    Winsize(buf[1], buf[2], buf[3], buf[4])

"""Apply a Winsize to a pty fd via the non-variadic C shim; throws on failure."""
function setWindowSizeOn(fd::Cint, ws::Winsize)
    rc = ccall((:flootySetWinsize, SHIM_LIB), Cint,
               (Cint, Cint, Cint), fd, Cint(ws.wsRow), Cint(ws.wsCol))
    rc == 0 || error("ioctl(TIOCSWINSZ) failed: $(Libc.strerror(Libc.errno()))")
    return fd
end

"""Read the window size on `fd` via the C shim; returns (rows, cols)."""
function getWindowSizeOn(fd::Cint)
    rOut = Ref{Cint}(0)
    cOut = Ref{Cint}(0)
    rc = ccall((:flootyGetWinsize, SHIM_LIB), Cint,
               (Cint, Ptr{Cint}, Ptr{Cint}), fd, rOut, cOut)
    rc == 0 || error("ioctl(TIOCGWINSZ) failed: $(Libc.strerror(Libc.errno()))")
    return (Int(rOut[]), Int(cOut[]))
end

"""Set O_NONBLOCK on `fd` so the read task can poll without blocking the scheduler."""
function makeNonBlocking!(fd::Cint)
    cur = ccall(:fcntl, Cint, (Cint, Cint), fd, F_GETFL_FLAG)
    cur >= 0 || error("fcntl(F_GETFL) failed: $(Libc.strerror(Libc.errno()))")
    rc = ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, F_SETFL_FLAG, cur | O_NONBLOCK_FLAG)
    rc >= 0 || error("fcntl(F_SETFL) failed: $(Libc.strerror(Libc.errno()))")
    return fd
end

"""Best-effort fd close that never throws (used in cleanup paths)."""
closeQuietly(fd::Cint) = fd >= 0 && ccall((:close, "libc"), Cint, (Cint,), fd)

# ---- spawn support (parent side) ---------------------------------------------

"""
Normalize a Cmd's exec/dir/env fields, which arrive as `nothing` or various
iterables depending on how the Cmd was constructed.
"""
function normalizeCmdFields(cmd::Cmd)
    exec = String[string(x) for x in getfield(cmd, :exec)]
    d = getfield(cmd, :dir)
    # Cmd.dir defaults to "" (not nothing) when unset — treat empty as no dir.
    dir = d isa AbstractString && !isempty(d) ? String(d) : nothing
    e = getfield(cmd, :env)
    env = e isa Nothing ? String[] :
        String[x isa Pair ? string(first(x)) * "=" * string(last(x)) : string(x)
               for x in e]
    return (; exec, dir, env)
end

"""Snapshot the live environment as "K=V" strings straight from libc `environ`."""
function parentEnvironmentStrings()
    out = String[]
    # cglobal gives the ADDRESS OF the `environ` slot; deref once to get char**,
    # then walk the NULL-terminated string table.
    envpp = unsafe_load(convert(Ptr{Ptr{Ptr{Cchar}}},
                                cglobal((:environ, "libc"))))
    envpp == C_NULL && return out
    i = 1
    while true
        p = unsafe_load(envpp, i)
        p == C_NULL && break
        push!(out, unsafe_string(p))
        i += 1
    end
    return out
end

# Color contract for pane children. A pane IS a full-color xterm, so the app
# forces the terminal identity — and must force the color DECISION with it.
# `NO_COLOR` is inherited from whatever launched the app (a harness, CI-ish
# shell or terminal that wants ITS OWN stdout plain); letting it leak into the
# panes greys out everything those children print — shell prompts, git/ls and
# the julia REPL all honor it, and the escape sequences never reach xterm.
const PTY_CHILD_ENV_FORCE = ("TERM=xterm-256color", "COLORTERM=truecolor")
const PTY_CHILD_ENV_DROP = (
    "NO_COLOR",
    # PROJECT ACTIVATION must not leak into panes. The app itself is launched with
    # its project activated (the Pkg.Apps shim exports
    # JULIA_LOAD_PATH=…/dev/Flooty), and a pane is the USER's terminal: with
    # these inherited, every `julia` typed in a tab reports
    # "Activating project at …/Flooty" and resolves packages against the
    # app's checkout. The depot stays inherited on purpose.
    "JULIA_LOAD_PATH",
    "JULIA_PROJECT",
)

"""Merge normalized `Cmd.env` "K=V" pairs over the inherited environment.
`drop` names inherited keys (e.g. color kill-switches) removed before the
override pairs are applied."""
function mergedEnvironment(envPairs::Vector{String};
                           drop::Tuple{Vararg{String}} = ())
    dict = Dict{String,String}()
    for entry in parentEnvironmentStrings()
        eq = findfirst('=', entry)
        eq === nothing ? (dict[entry] = "") : (dict[entry[1:eq-1]] = entry[eq+1:end])
    end
    for k in drop
        delete!(dict, k)
    end
    for pair in envPairs
        parts = split(pair, '='; limit=2)
        length(parts) == 2 && (dict[String(parts[1])] = String(parts[2]))
    end
    return String["$k=$v" for (k, v) in sort!(collect(dict))]
end

"""Call `f` with a NUL-terminated char** built from `items` (GC-safe within)."""
function withCharStarArray(f, items::Vector{String})
    bufs = [vcat(codeunits(s), 0x00) for s in items]
    arr = Ptr{UInt8}[pointer(b) for b in bufs]
    push!(arr, C_NULL)
    return GC.@preserve bufs arr f(convert(Ptr{Ptr{Cchar}}, pointer(arr)))
end

"""Zeroed sigset_t buffer with `signals` added (for POSIX_SPAWN_SETSIGDEF)."""
function sigsetDefaultSet(signals::Tuple{Vararg{Cint}})
    buf = zeros(UInt8, SIGSET_BUF_BYTES)
    GC.@preserve buf begin
        p = convert(Ptr{Cvoid}, pointer(buf))
        ccall(:sigemptyset, Cint, (Ptr{Cvoid},), p)
        for s in signals
            ccall(:sigaddset, Cint, (Ptr{Cvoid}, Cint), p, s)
        end
    end
    return buf
end

quietlyDestroySpawnObjects(actions::Ptr{Cvoid}, attr::Ptr{Cvoid}) =
    try
        ccall((:posix_spawn_file_actions_destroy, "libc"), Cint, (Ptr{Cvoid},), actions)
        ccall((:posix_spawnattr_destroy, "libc"), Cint, (Ptr{Cvoid},), attr)
    catch
    end

"""Resolve the slave device path (e.g. /dev/ttys007) via the shim-wrapped ptsname."""
function slaveDevicePath(masterFd::Cint)::Vector{UInt8}
    buf = Vector{UInt8}(undef, 256)
    rc = ccall((:flootySlaveName, SHIM_LIB), Cint,
               (Cint, Ptr{UInt8}, Cint), masterFd, buf, length(buf))
    rc == 0 || error("ptsname failed: $(Libc.strerror(Libc.errno()))")
    return buf
end

"""
Spawn `cmd` ATTACHED to the PTY slave WITHOUT ever calling fork() from Julia.

On Darwin, fork() from the multithreaded Julia VM kills the child before it
can execute anything (libuv kqueue assertion + Objective-C fork-safety abort;
reproduced minimally in test/debugForkMin.jl). Instead we posix_spawn the
compiled flootySpawnHelper binary: it becomes a session leader, opens the
slave device by path (acquiring it as controlling terminal on BSD/macOS),
dup2s it onto stdin/stdout/stderr, chdirs, and execvp's the requested argv.
Env overrides are applied parent-side via a merged environ passed to
posix_spawnp; TERM=xterm-256color is injected the same way.
Parent side closes the slave and returns the child pid.
"""
function spawnChildAttached(masterFd::Cint, slaveFd::Cint, cmd::Cmd)::Int32
    spec = normalizeCmdFields(cmd)
    isempty(spec.exec) && throw(ArgumentError("Cmd has an empty exec vector"))
    slavePathBytes = slaveDevicePath(masterFd)
    nulIdx = findfirst(==(0x00), slavePathBytes)
    slavePath = String(nulIdx === nothing ? slavePathBytes : slavePathBytes[1:nulIdx-1])

    argvItems = String[HELPER_EXE, slavePath, spec.dir === nothing ? "-" : spec.dir,
                       spec.exec...]
    envPairs = copy(spec.env)
    append!(envPairs, PTY_CHILD_ENV_FORCE)

    actionsBuf = zeros(UInt8, SPAWN_OBJ_BUF_BYTES)
    attrBuf = zeros(UInt8, SPAWN_OBJ_BUF_BYTES)
    maskBuf = zeros(UInt8, SIGSET_BUF_BYTES)   # empty mask => nothing blocked
    defBuf = sigsetDefaultSet((Cint(2), Cint(3), SIGTSTP_SIGNAL,
                               SIGTTIN_SIGNAL, SIGTTOU_SIGNAL))

    GC.@preserve actionsBuf attrBuf maskBuf defBuf begin
        actions = convert(Ptr{Cvoid}, pointer(actionsBuf))
        attr = convert(Ptr{Cvoid}, pointer(attrBuf))
        ccall((:posix_spawn_file_actions_init, "libc"), Cint, (Ptr{Cvoid},), actions)
        ccall((:posix_spawn_file_actions_addclose, "libc"), Cint,
              (Ptr{Cvoid}, Cint), actions, masterFd)
        ccall((:posix_spawn_file_actions_addclose, "libc"), Cint,
              (Ptr{Cvoid}, Cint), actions, slaveFd)
        ccall((:posix_spawnattr_init, "libc"), Cint, (Ptr{Cvoid},), attr)
        flags = POSIX_SPAWN_SETSIGDEF_FLAG | POSIX_SPAWN_SETSIGMASK_FLAG
        Sys.isapple() && (flags |= POSIX_SPAWN_SETSID_FLAG |
                                   POSIX_SPAWN_CLOEXEC_DEFAULT_FLAG)
        ccall((:posix_spawnattr_setflags, "libc"), Cint,
              (Ptr{Cvoid}, Culong), attr, flags)
        ccall((:posix_spawnattr_setsigdefault, "libc"), Cint,
              (Ptr{Cvoid}, Ptr{Cvoid}), attr, convert(Ptr{Cvoid}, pointer(defBuf)))
        ccall((:posix_spawnattr_setsigmask, "libc"), Cint,
              (Ptr{Cvoid}, Ptr{Cvoid}), attr, convert(Ptr{Cvoid}, pointer(maskBuf)))

        pidRef = Ref{Cint}(0)
        # ALWAYS build the environment (never pass the inherited `environ` through):
        # the drop list must apply to EVERY pane child, not only to shells that get
        # an override pair. Inheriting verbatim leaked the app's project activation
        # (JULIA_LOAD_PATH) and NO_COLOR into the user's terminals.
        envItems = mergedEnvironment(envPairs; drop = PTY_CHILD_ENV_DROP)
        rc = withCharStarArray(argvItems) do argvP
            withCharStarArray(envItems) do envP
                ccall((:posix_spawnp, "libc"), Cint,
                      (Ref{Cint}, Cstring, Ptr{Cvoid}, Ptr{Cvoid},
                       Ptr{Ptr{Cchar}}, Ptr{Ptr{Cchar}}),
                      pidRef, HELPER_EXE, actions, attr, argvP, envP)
            end
        end
        quietlyDestroySpawnObjects(actions, attr)
    end

    # posix_spawn RETURNS the errno rather than setting thread-local errno.
    rc == 0 || error("posix_spawn failed with errno=$rc ($(Libc.strerror(rc)))")
    # NOTE: the parent's slave fd is NOT closed here. It is handed back to
    # spawnPty, which keeps it alive across the helper's attach window
    # (same strategy as Warp's make_pty/spawn pair) and closes it shortly
    # after, once the child has acquired its own slave fds.
    return Int32(pidRef[])
end

# ---- streaming read loop ----------------------------------------------------

struct _PollFD
    fd::Cint
    events::Int16
    revents::Int16
end

"""
Wait until `fd` is readable (bounded by `timeoutMs`).

Returns 1 when the fd is ready, 0 on timeout (nothing to read yet) and -1 on
a poll error. `poll` is used instead of a plain blocking read so the reader
thread wakes at least every few ms: a thread parked in `read()` forever would
keep the process alive at exit, because Julia waits for its threads.
"""
function pollReadable(fd::Cint, timeoutMs::Int)
    pfd = Ref(_PollFD(fd, Int16(0x0001), Int16(0)))   # POLLIN
    ready = ccall(:poll, Cint, (Ptr{_PollFD}, Culong, Cint), pfd, 1, timeoutMs)
    ready < 0 && return -1
    return ready == 0 ? 0 : 1
end

"""
Read task body: pushes the PTY's output onto `h.outputCh` as byte batches.
On EOF/error (or handle close) flips `h.open` to false and closes the channel
exactly once.

TWO READ STRATEGIES (see spawnPty):
  * blocking (a thread of its own): the fd is waited on with poll(), so the
    kernel wakes the reader the moment a byte arrives. The macOS tty output
    queue is 1 KiB, so a POLLING reader could never drain it faster than
    (queue size / poll interval) — measured 0.14 MiB/s with the old fixed
    5 ms poll (1.42 MiB took 10 s), and 70+ MiB/s with the blocking reader.
  * polling (single-threaded runtime): a non-blocking fd with an adaptive
    interval — 0.2 ms while output flows, 5 ms when idle.

Darwin spawn race: `spawnChildAttached` closes the parent's slave fd as soon
as posix_spawnp returns, but the spawned helper does not open the slave
device (setsid -> open(slavePath)) until a moment later. In that window ZERO
slave fds exist and read(master) returns 0 (EOF-shaped) instead of blocking,
so a reader task that wins the race would kill a perfectly healthy session.
We therefore ignore data-less EOF until either some output has flowed or
SPAWN_EOF_GRACE_SECONDS has elapsed; genuine EOF (slave closed after output,
or a spawn that never opened the slave at all) still ends the loop promptly.
"""
function masterReadLoop(h::PtyHandle)
    buffer = Vector{UInt8}(undef, READ_BUFFER_BYTES)
    startMonotonic = time()
    sawData = false
    pollDelay = READ_POLL_MIN_SECONDS
    # Reads are COALESCED before they enter the channel: a blocking read
    # returns whatever the kernel has — often a handful of bytes — and 1 MiB
    # of output arrived as 128k tiny chunks (one channel put and one task
    # switch each) before this.
    batch = UInt8[]
    blocking = h.blockingReader
    # A batch is flushed when it is big enough OR when the PTY went quiet —
    # a small output (a shell prompt!) must not sit in the batch waiting for
    # 16 KiB.
    function flushBatch!()
        isempty(batch) && return
        chunk = batch
        batch = UInt8[]
        try
            put!(h.outputCh, chunk)
        catch
        end
    end
    try
        while true
            h.open || break
            if blocking
                # Wait for readability (bounded), then read. A poll timeout is
                # NOT an EOF — only read() == 0 is. The timeout is LONG on
                # purpose: poll returns the moment a byte arrives, so the
                # timeout only bounds how fast we notice the PTY closing.
                ready = pollReadable(h.masterFd, 100)
                ready < 0 && break              # poll error: the fd is gone
                if ready == 0
                    flushBatch!()                # the PTY went quiet
                    continue
                end
                n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                          h.masterFd, buffer, length(buffer))
            else
                n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                          h.masterFd, buffer, length(buffer))
            end
            if n > 0
                sawData = true
                pollDelay = READ_POLL_MIN_SECONDS
                append!(batch, view(buffer, 1:n))
                # COALESCE THE TTY'S PIECES. The macOS tty output queue is
                # 1 KiB, so a full-screen redraw (broot, micro, vim) arrives
                # as a dozen short reads. Handing each one over separately
                # paints the screen band by band — the raster scan. So wait a
                # moment for the rest of the burst before handing it over; a
                # keystroke echo waits at most READ_COALESCE_SECONDS.
                if length(batch) < READ_BATCH_BYTES
                    deadline = time() + READ_COALESCE_SECONDS
                    while time() < deadline && length(batch) < READ_BATCH_BYTES
                        pollReadable(h.masterFd, 1) == 1 || break
                        m = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                                  h.masterFd, buffer, length(buffer))
                        m > 0 || break
                        append!(batch, view(buffer, 1:m))
                    end
                end
                chunk = batch
                batch = UInt8[]
                try
                    put!(h.outputCh, chunk)
                catch
                    break  # channel closed underneath us
                end
            elseif n == 0
                if sawData || time() - startMonotonic > SPAWN_EOF_GRACE_SECONDS
                    break  # real EOF: slave-side fds all closed
                end
                sleep(READ_POLL_SECONDS)  # ride out the spawn race
            else
                errno = Libc.errno()
                if errno == EINTR_ERRNO
                    continue
                elseif errno == EAGAIN_ERRNO
                    h.open || break
                    sleep(pollDelay)
                    pollDelay = min(pollDelay * 2, READ_POLL_MAX_SECONDS)
                else
                    break  # EBADF/EIO/etc.: master gone or fatal
                end
            end
        end
    finally
        flushBatch!()
        h.open = false
        isopen(h.outputCh) && close(h.outputCh)
    end
    return nothing
end

# ---- contract methods -------------------------------------------------------

"""
    spawnPty(cmd::Cmd; rows=24, cols=80) :: PtyHandle

Create a master/slave PTY pair, size it to `rows`×`cols`, fork a child
attached to the slave (setsid + TIOCSCTTY + dup2 + exec of `cmd`'s argv,
honoring the Cmd's env/dir when set), and start an async task streaming
master-side output chunks into the returned handle's channel.
"""
function spawnPty(cmd::Cmd; rows::Int=24, cols::Int=80)
    masterFd, slaveFd = createPtyPair()
    local pid::Int32
    try
        setWindowSizeOn(slaveFd, Winsize(rows, cols))
        pid = spawnChildAttached(masterFd, slaveFd, cmd)
    catch e
        closeQuietly(masterFd)
        closeQuietly(slaveFd)
        rethrow(e)
    end
    # The reader: with more than one thread available, the master fd is read
    # on a thread of its own, waiting for readability with poll() — the kernel
    # wakes the reader the moment a byte arrives, so the 1 KiB macOS tty
    # queue never becomes the bottleneck (measured: 0.14 MiB/s with the old
    # fixed 5 ms poll, 70+ MiB/s with the blocking reader). A blocking ccall
    # inside a Julia task would pin the scheduler, so it only happens on a
    # thread of its own; with a single thread we keep the adaptive poll.
    useBlockingReader = Threads.nthreads() > 1
    useBlockingReader || makeNonBlocking!(masterFd)
    # Hold the parent's slave fd across the helper's setsid->open(slavePath)
    # attach window so read(master) blocks instead of reporting a phantom EOF
    # (Warp does exactly this: "keep it alive long enough"). Closed after
    # SLAVE_HOLD_SECONDS; the helper normally owns the slave within ms.
    @async begin
        sleep(SLAVE_HOLD_SECONDS)
        closeQuietly(slaveFd)
    end
    h = PtyHandle(uuid4(), masterFd, pid, Channel{Vector{UInt8}}(Inf),
                  ReentrantLock(), nothing, true, nothing, useBlockingReader)
    if useBlockingReader
        h.readTask = Threads.@spawn masterReadLoop(h)
    else
        h.readTask = @async masterReadLoop(h)
    end
    return h
end

"""
    writeToPty(h::PtyHandle, bytes::Vector{UInt8}; source=:agent)

Write raw bytes to the PTY master (looping over partial writes), serialized
by `h.writeLock`. `source` (:user or :agent) is validated and recorded for
future write-gating by the control layer; it is otherwise a no-op today.
Returns the number of bytes written.
"""
function writeToPty(h::PtyHandle, bytes::Vector{UInt8}; source::Symbol=:agent)
    source in (:user, :agent) ||
        throw(ArgumentError("source must be :user or :agent, got $source"))
    return lock(h.writeLock) do
        h.open || error("writeToPty: pty $(h.id) is closed")
        total = length(bytes)
        offset = 1
        deadline = time() + 10.0
        while offset <= total
            n = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                      h.masterFd, pointer(bytes, offset), total - offset + 1)
            if n < 0
                errno = Libc.errno()
                # A large `type` payload (a file/heredoc) can fill the PTY
                # input buffer faster than the child drains it. EAGAIN is flow
                # control, not a failure — wait and retry.
                if errno == Libc.EAGAIN
                    time() >= deadline &&
                        error("write to pty stalled: input buffer full for 10s")
                    sleep(0.005)
                    continue
                end
                error("write to pty failed: $(Libc.strerror(errno))")
            end
            n == 0 && error("write to pty made no progress")
            offset += n
        end
        total
    end
end

"""Output stream for this PTY: a channel of raw byte chunks as read from the master fd."""
outputChannel(h::PtyHandle) = h.outputCh

"""
    resizePty!(h::PtyHandle, rows::Int, cols::Int)

Resize the terminal window via ioctl(TIOCSWINSZ) on the master fd; the child
receives SIGWINCH automatically.
"""
function resizePty!(h::PtyHandle, rows::Int, cols::Int)
    lock(h.writeLock) do
        h.open || error("resizePty!: pty $(h.id) is closed")
        setWindowSizeOn(h.masterFd, Winsize(rows, cols))
    end
    return h
end

"Decode a waitpid status into a shell-style exit code (128+n for signals)."
function decodeExitStatus(status::Cint)::Int
    st = Int(status)
    if st & 0x7f == 0
        return (st >> 8) & 0xff
    end
    return 128 + (st & 0x7f)
end

"""Poll-wait for the child to exit, escalating to SIGKILL after `graceS`; returns true once reaped."""
function reapChild!(h::PtyHandle; graceS::Float64=2.0)
    status = Ref{Cint}(0)
    deadline = time() + graceS
    while true
        r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint),
                  h.pid, status, Cint(1))  # WNOHANG
        r == h.pid && (h.exitStatus = decodeExitStatus(status[]); return true)
        r == -1 && Libc.errno() == ECHILD_ERRNO && return true  # already reaped
        time() >= deadline && break
        sleep(0.02)
    end
    ccall(:kill, Cint, (Cint, Cint), h.pid, SIGKILL_SIGNAL)
    deadline = time() + graceS
    while time() < deadline
        r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), h.pid, status, Cint(1))
        r == h.pid && (h.exitStatus = decodeExitStatus(status[]); return true)
        r == -1 && Libc.errno() == ECHILD_ERRNO && return true
        sleep(0.02)
    end
    return false
end

"""
    closePty!(h::PtyHandle)

Terminate the child gracefully (SIGTERM, SIGKILL fallback), reap it so no
zombie remains, close the master fd, flip `open` to false, and close the
output channel. Safe to call more than once.
"""
function closePty!(h::PtyHandle)
    firstClose = false
    lock(h.writeLock) do
        if h.open
            h.open = false
            firstClose = true
        end
    end
    if firstClose
        if h.pid > 0
            ccall(:kill, Cint, (Cint, Cint), h.pid, SIGTERM_SIGNAL)
            reapChild!(h)
        end
        closeQuietly(h.masterFd)
        h.masterFd = Cint(-1)
    end
    isopen(h.outputCh) && close(h.outputCh)
    if h.readTask !== nothing && !istaskdone(h.readTask)
        try
            wait(h.readTask)
        catch
        end
    end
    return h
end
"""Read the PTY's current (rows, cols) winsize, defaulting to 24×80 on error."""
function ptyWinsize(h::PtyHandle)
    rows = Ref{Cint}(24)
    cols = Ref{Cint}(80)
    try
        ccall((:flootyGetWinsize, SHIM_LIB), Cint, (Cint, Ptr{Cint}, Ptr{Cint}),
              h.masterFd, rows, cols)
    catch
    end
    return (Int(rows[]), Int(cols[]))
end
