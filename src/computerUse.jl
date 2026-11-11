# Remote computer-use server: external clients (FlootyComputerUse) speak a
# line-protocol over TCP. We accept newline-delimited JSON objects:
#   {"id":"u1","op":"evaluate"|"mouse"|"keyboard"|"screenshot","params":{...}}
# We reply on the same socket line with either "ok":true,"result":<json-string>
# or "ok":false,"error":<string>.
#
# The page is the control plane for in-page actions (JS evaluation); native
# actions (screenshot via CoreGraphics) are handled here. OS-level input uses
# CGEventPost and may require Accessibility permission.

using Sockets

const COMPUTER_USE_PORT = Ref{Int}(0)
const COMPUTER_USE_PENDING = Dict{String, Channel{Any}}()
const COMPUTER_USE_LOCK = ReentrantLock()

"""Start the computer-use TCP server on loopback. Returns the port."""
function startComputerUseServer!(; port::Int=0, host::String="127.0.0.1")
    lock(COMPUTER_USE_LOCK) do
        COMPUTER_USE_PORT[] != 0 && return COMPUTER_USE_PORT[]
        server = Sockets.listen(UInt16(port))
        _host, port = Sockets.getsockname(server)
        port = Int(port)
        COMPUTER_USE_PORT[] = port
        @info "computer-use: listening" host port
        ENV["FLOOTY_COMPUTER_USE_PORT"] = string(port)
        open(joinpath(tempdir(), "flooty-computer-use.port"), "w") do io
            write(io, string(port))
        end
        Threads.@spawn begin
            try
                _computerUseAcceptLoop(server)
            catch err
                @debug "computer-use accept loop ended" exception = err
            end
        end
        port
    end
end

computerUsePort() = COMPUTER_USE_PORT[]

function _computerUseAcceptLoop(server)
    while true
        sock = try Sockets.accept(server) catch; break end
        try
            peer = Sockets.getsockname(sock)
            @info "[ui-drop] computer-use accepted connection" peer
        catch
        end
        Threads.@spawn begin
            try
                _computerUseClientLoop(sock)
            catch err
                @debug "computer-use client loop ended" exception = err
            finally
                try close(sock) catch; end
            end
        end
    end
end

function _computerUseClientLoop(sock)
    while isopen(sock)
        line = try readline(sock) catch; break end
        @info "computer-use: received line" line
        isempty(strip(line)) && continue
        msg = try
            JSON.parse(line)
        catch err
            println(sock, JSON.json(Dict("id" => "", "ok" => false, "error" => string("parse: ", sprint(showerror, err)))))
            continue
        end
        id = String(get(msg, "id", ""))
        op = String(get(msg, "op", ""))
        params = get(msg, "params", Dict{String, Any}())
        @info "computer-use: parsed request" id op
        ch = Channel{String}(1)
        COMPUTER_USE_PENDING[id] = ch
        try
            println("computer-use: op=", op, ", params type=", typeof(params)); flush(stdout)
            if op == "evaluate"
                println("computer-use: branch=evaluate"); flush(stdout)
                _computerUseEvaluateRemote(id, ch, String(get(params, :script, "")))
            elseif op == "mouse" || op == "keyboard"
                _computerUseActRemote(id, ch, msg)
            elseif op == "screenshot"
                _computerUseScreenshot(id, ch)
            else
                delete!(COMPUTER_USE_PENDING, id)
                _write_reply!(ch, Dict("id" => id, "ok" => false, "error" => string("unknown op: ", op)))
            end
        catch err
            try delete!(COMPUTER_USE_PENDING, id) catch; end
            _write_reply(sock, Dict("id" => id, "ok" => false, "error" => sprint(showerror, err)))
        end
        wait_for_and_write_reply!(sock, id, ch)
    end
end

function _computerUseEvaluateRemote(id::String, ch::Channel{String}, script::String)
    println("computer-use: dispatch about to happen (id=", id, " script=", script, ")")
    wv = activeTerminalUiWebview()
    if wv === nothing
        println("computer-use: NO WEBVIEW")
        return _write_reply_now!(ch, Dict("id" => id, "ok" => false, "error" => "no active webview"))
    end
    println("computer-use: dispatch entered, wv type=", typeof(wv))
    try
        @info "computer-use: calling page" id script=String(script)
        println("computer-use: calling eval!")
        Webviews.eval!(wv,
            "window.__computerUseRequest(\"" * escapeJsString(id) * "\", " *
            JSON.json("{\"id\":\"" * id * "\",\"script\":" * JSON.json(script) * "}") *
            ");")
        println("computer-use: eval! returned")
    catch err
        println("computer-use: eval threw: ", sprint(showerror, err))
        _write_reply!(ch, Dict("id" => id, "ok" => false, "error" => sprint(showerror, err)))
    end
end

function _computerUseActRemote(id::String, ch::Channel{String}, msg)
    wv = activeTerminalUiWebview()
    wv === nothing && return _write_reply_now!(ch, Dict("id" => id, "ok" => false, "error" => "no active webview"))
    Webviews.dispatch(wv) do
        try
            Webviews.eval!(wv,
                "window.__computerUseAct(" *
                JSON.json(msg) *
                ");")
        catch err
            _write_reply!(ch, Dict("id" => id, "ok" => false, "error" => sprint(showerror, err)))
        end
    end
end

function _write_reply_now!(ch::Channel{String}, dict)
    @async try put!(ch, JSON.json(dict)) catch; end
    return nothing
end

function _write_reply!(ch::Channel{String}, dict)
    put!(ch, JSON.json(dict))
end

function _write_reply(sock, dict)
    println(sock, JSON.json(dict))
end

function wait_for_and_write_reply!(sock, id::String, ch::Channel{String}; timeout::Float64=5.0)
    deadline = time() + timeout
    while true
        if isready(ch)
            reply = take!(ch)
            println(sock, reply)
            return
        end
        if time() >= deadline
            try delete!(COMPUTER_USE_PENDING, id) catch; end
            _write_reply(sock, Dict("id" => id, "ok" => false, "error" => "timeout waiting for reply"))
            return
        end
        sleep(0.005)
    end
end

# Write-through: the page reports back via the bound Julia callback.
function computerUseReply(id::AbstractString, ok::Bool, payload::Any)
    ch = pop!(COMPUTER_USE_PENDING, id, nothing)
    ch !== nothing && put!(ch, JSON.json(Dict("id" => String(id), "ok" => ok, "result" => payload)))
    return true
end

include("computerUseCapture.jl")
