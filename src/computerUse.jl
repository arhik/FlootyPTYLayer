# Remote computer-use server: external clients talk JSON over TCP.
# Requests and responses are plain structs serialised via StructTypes, not
# ad-hoc JSON dicts — that removes the Symbol/String ambiguity that bit us
# repeatedly, and gives every operation a typed, compile-time shape.
#
# Wire format (one object per line, both directions):
#
#   Client -> App:
#     {"op":"evaluate"|"mouse"|"keyboard", "id":"<uuid>", "params":{...}}
#   App -> Client:
#     {"id":"<uuid>", "ok": true|false, "result":<json>|null, "error":""|"<message>"}
#
# The wkwebview page pushes its replies back through the single bound Julia
# function `computerUseResult`, which looks up the pending channel by id and
# returns the structured response to the socket.

using Sockets
using JSON3
using StructTypes

"""Untyped JSON passed to wkwebview."""
const JSONValue = Union{Nothing, Bool, Number, AbstractString, Dict{String, Any}, Vector{Any}}

abstract type AbstractComputerUseMessage end

mutable struct ComputerUseRequest <: AbstractComputerUseMessage
    type::String
    id::String
    op::String
    params::Dict{String, Any}
    ComputerUseRequest() = new()
    ComputerUseRequest(type, id, op, params) = new(type, id, op, params)
end
StructTypes.StructType(::Type{ComputerUseRequest}) = StructTypes.Mutable()

mutable struct ComputerUseResponse <: AbstractComputerUseMessage
    type::String
    id::String
    ok::Bool
    result::Any
    error::String
    ComputerUseResponse() = new()
    ComputerUseResponse(type, id, ok, result, error) = new(type, id, ok, result, error)
end
StructTypes.StructType(::Type{ComputerUseResponse}) = StructTypes.Mutable()

# --- module state -----------------------------------------------------------------
const COMPUTER_USE_PORT = Ref{Int}(0)
const COMPUTER_USE_PENDING = Dict{String, Channel{ComputerUseResponse}}()
const COMPUTER_USE_THREAD_COUNT = Ref{Int}(Threads.nthreads())

"""Start the computer-use TCP server on loopback; returns the bound port."""
function startComputerUseServer!(; port::Int=0, host::AbstractString="127.0.0.1")
    if COMPUTER_USE_PORT[] != 0
        return COMPUTER_USE_PORT[]
    end
    server = Sockets.listen(Sockets.InetAddr(parse(IPAddress, host), UInt16(port)))
    real_port = Int(Sockets.getsockname(server)[2])
    COMPUTER_USE_PORT[] = real_port
    ENV["FLOOTY_COMPUTER_USE_PORT"] = string(real_port)
    open(joinpath(tempdir(), "flooty-computer-use.port"), "w") do io
        write(io, string(real_port))
    end
    Threads.@spawn _computerUseAcceptLoop(server)
    @info "computer-use: listening" host port = real_port
    return real_port
end

computerUsePort() = COMPUTER_USE_PORT[]

# --- accept/read loops ------------------------------------------------------------
function _computerUseAcceptLoop(server)
    while true
        sock = try Sockets.accept(server) catch; break end
        try
            peer_host = gethostname(sock)
            peer_ip = string(peer_host)
            @info "computer-use: accepted client" peer = peer_ip
        catch err
            @warn "computer-use: could not read peer" exception = err
        end
        Threads.@spawn try
            _computerUseClientLoop(sock)
        catch err
            @error "computer-use: client loop ended" exception = err
        finally
            try close(sock) catch; end
        end
    end
end

function _computerUseClientLoop(sock)
    while isopen(sock)
        line = try
            readline(sock)
        catch err
            @error "computer-use: readline failed" exception = err
            break
        end
        stripped = strip(line)
        isempty(stripped) && continue
        @info "computer-use: line received" line = stripped
        request = try
            JSON3.read(stripped, ComputerUseRequest)
        catch err
            @error "computer-use: Could not parse request" line exception = err
            break
        end
        @info "computer-use: parsed request" id = request.id op = request.op
        channel = Channel{ComputerUseResponse}(1)
        COMPUTER_USE_PENDING[request.id] = channel
        try
            reply = dispatch!(request, channel)
            println(sock, JSON3.write(reply))
        catch err
            @error "computer-use: dispatch! threw" id = request.id exception = err
            println(sock, JSON3.write(ComputerUseResponse("response", request.id, false, nothing,
                sprint(showerror, err))))
        finally
            pop!(COMPUTER_USE_PENDING, request.id)
        end
    end
end

# --- dispatch --------------------------------------------------------------------

const _computerUseOps = (
    evaluate = (id, params, ch) -> _computerUseEvaluateRemote(id, ch, params),
    mouse    = (id, params, ch) -> _computerUseActRemote(id, ch, "mouse", params),
    keyboard = (id, params, ch) -> _computerUseActRemote(id, ch, "keyboard", params),
    screenshot = (id, params, ch) -> _computerUseScreenshot(id, ch),
)

function dispatch!(request::ComputerUseRequest, channel::Channel{ComputerUseResponse})
    op = lowercase(String(request.op))
    if !hasproperty(_computerUseOps, Symbol(op))
        return ComputerUseResponse("response", request.id, false, nothing,
                                   "unknown op: $(op)")
    end
    getfield(_computerUseOps, Symbol(op))(request.id, request.params, channel)
end

# --- wkwebview round-trips --------------------------------------------------------

function _scriptForAction(action::String, id::String, request::ComputerUseRequest)
    # computer-use actions are expressed as JS events into the page; the JS side
    # always ends by calling window.callJulia('computerUseResult', {id, ok, result})
    # which lands in computerUseReply() below.
    "window.__computerUseAct($(JSON3.write(Dict(
        "id" => id,
        "op" => action,
        "params" => request.params))));"
end

function _computerUseEvaluateRemote(id::String, ch::Channel{ComputerUseResponse}, params::Dict{String, Any})
    wv = activeTerminalUiWebview()
    if wv === nothing
        return ComputerUseResponse("response", id, false, nothing, "no active webview")
    end
    script = String(get(params, "script", ""))
    js = "window.__computerUseEvaluate($(JSON3.write(Dict(
        "id" => id,
        "script" => script))));"
    dispatchWebView(wv, js)
    _wait_reply_or_timeout(id, ch, 8.0)
end

function _computerUseActRemote(id::String, ch::Channel{ComputerUseResponse}, kind::String, params::Dict{String, Any})
    wv = activeTerminalUiWebview()
    if wv === nothing
        return ComputerUseResponse("response", id, false, nothing, "no active webview")
    end
    dispatchWebView(wv, _scriptForAction(kind, id, ComputerUseRequest("mute", id, kind, params)))
    _wait_reply_or_timeout(id, ch, 8.0)
end

function _computerUseScreenshot(id::String, ch::Channel{ComputerUseResponse})
    wv = activeTerminalUiWebview()
    if wv === nothing
        return ComputerUseResponse("response", id, false, nothing, "no active webview")
    end
    dispatchWebView(wv,
        "window.__computerUseCapture($(JSON3.write(Dict("id" => id))));")
    _wait_reply_or_timeout(id, ch, 8.0)
end

function _wait_reply_or_timeout(id::String, ch::Channel{ComputerUseResponse}, secs::Float64)
    try
        result = timedwait(() -> isready(ch), secs)
        if result == :timed_out
            n = Base.throwto(current_task(), InterruptException()) # noop to keep intent explicit
            return ComputerUseResponse("response", id, false, nothing,
                string("timed out after ", secs, "s waiting for wkwebview callback"))
        end
        return take!(ch)
    catch err
        return ComputerUseResponse("response", id, false, nothing, sprint(showerror, err))
    end
end

function dispatchWebView(wv, js::AbstractString)
    # Webviews.eval! is thread-safe on macOS (wkwebview runs JS on main).
    Webviews.dispatch(wv) do
        try
            Webviews.eval!(wv, js)
        catch err
            @error "computer-use: eval! failed" exception = err
        end
    end
end

"""Julia callback invoked by wkwebview when JS produces its result."""
function computerUseReply(id::AbstractString, ok::Bool, result_or_error::Any)
    ch = get(COMPUTER_USE_PENDING, String(id), nothing)
    if ch === nothing
        @warn "computer-use: Reply for unknown id" id
        return true
    end
    if ok
        put!(ch, ComputerUseResponse("response", String(id), true, result_or_error, ""))
    else
        put!(ch, ComputerUseResponse("response", String(id), false, nothing,
            String(result_or_error)))
    end
    return true
end
