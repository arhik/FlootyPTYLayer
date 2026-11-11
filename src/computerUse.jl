# Remote computer-use server: external clients talk JSON over TCP.
# Wire format (one object per line, both directions):
#
#   Client -> App:
#     {"id":"<uuid>","op":"evaluate"|"mouse"|"keyboard"|"screenshot","params":{...}}
#   App -> Client:
#     {"id":"<uuid>","ok":true|false,"result":<json>|null,"error":""|"<message>"}
#
# Responses are JSON objects pushed from wkwebview via the bound
# `computerUseResult` Julia function; the server merges them with
# `COMPUTER_USE_PENDING` and writes a typed reply onto the socket.

using Sockets
using JSON
using UUIDs

const COMPUTER_USE_PORT = Ref{Int}(0)
const COMPUTER_USE_PENDING = Dict{String, Channel{Dict{String, Any}}}()

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

function _computerUseAcceptLoop(server)
    while true
        sock = try Sockets.accept(server) catch; break end
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
        s = strip(line)
        isempty(s) && continue
        request = try
            JSON.parse(s; dicttype = Dict{String, Any})
        catch err
            @error "computer-use: line did not parse" line exception = err
            break
        end
        id = String(get(request, "id", ""))
        op = String(get(request, "op", ""))
        params = get(request, "params", Dict{String, Any}())
        if isempty(id) || isempty(op)
            @warn "computer-use: missing id or op" line
            break
        end
        @info "computer-use: received" id op
        channel = Channel{Dict{String, Any}}(1)
        COMPUTER_USE_PENDING[id] = channel
        try
            reply = _dispatchComputerUse(id, op, params, channel)
            println(sock, JSON.json(reply))
        catch err
            @error "computer-use: dispatch threw" id exception = err
            println(sock, JSON.json(Dict("id" => id, "ok" => false, "error" => sprint(showerror, err))))
        finally
            pop!(COMPUTER_USE_PENDING, id)
        end
    end
end

function _computerUseEvaluateRemote(id::String, params::Dict{String, Any}, ch::Channel{Dict{String, Any}})
    wv = activeTerminalUiWebview()
    if wv === nothing
        return Dict{String, Any}("id" => id, "ok" => false, "error" => "no active webview")
    end
    script = String(get(params, "script", ""))
    safe = replace(script, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t",
                   "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026",
                   "\u2028" => "\\u2028", "\u2029" => "\\u2029")
    Webviews.eval!(wv,
        "window.__computerUseEvaluate($(JSON.json(Dict(
            "id" => id,
            "script" => script))));")
    return _wait_reply_or_timeout(id, ch, 8.0)
end

function _computerUseActRemote(id::String, ch::Channel{Dict{String, Any}}, kind::String, params::Dict{String, Any})
    wv = activeTerminalUiWebview()
    if wv === nothing
        return Dict{String, Any}("id" => id, "ok" => false, "error" => "no active webview")
    end
    Webviews.eval!(wv,
        "window.__computerUseAct($(JSON.json(Dict(
            "id" => id,
            "op" => kind,
            "params" => params))));")
    return _wait_reply_or_timeout(id, ch, 8.0)
end

function _computerUseScreenshot(id::String, params::Dict{String, Any}, ch::Channel{Dict{String, Any}})
    return Dict{String, Any}("id" => id, "ok" => false, "error" => "screenshot not implemented")
end

function _wait_reply_or_timeout(id::String, ch::Channel{Dict{String, Any}}, secs::Float64)
    deadline = time() + secs
    while time() < deadline
        if isready(ch)
            return take!(ch)
        end
        sleep(0.005)
    end
    return Dict{String, Any}("id" => id, "ok" => false,
                             "error" => string("timed out after ", secs, "s"))
end

"""Called by wkwebview via `computerUseResult(id, ok, result_or_error)`."""
function computerUseReply(id::AbstractString, ok::Bool, payload::Any)
    ch = get(COMPUTER_USE_PENDING, String(id), nothing)
    if ch === nothing
        @warn "computer-use: Reply for unknown id" id
        return true
    end
    if ok
        put!(ch, Dict{String, Any}("id" => String(id), "ok" => true, "result" => payload))
    else
        put!(ch, Dict{String, Any}("id" => String(id), "ok" => false,
                                   "error" => string(payload)))
    end
    return true
end
