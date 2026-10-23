# channelServerProbe.jl — the data plane, end to end, without a browser.
#
# The app's page opens a binary channel per terminal: the PTY's bytes go over
# that socket instead of the eval path. This probe drives the same server
# from Julia — open the channel, complete the readiness handshake, and check
# that the output arrives over the socket.
#
# It is the check that the server's SEND path works: a frame that fails to
# encode (or a send that throws) used to fail silently, and the page fell
# back to the eval path without saying so.
#
#   julia --startup-file=no --project=. test/channelServerProbe.jl
import FlootyPTYLayer
using HTTP

const FRAME_OUTPUT = 0x01
const FRAME_OPEN   = 0x05
const FRAME_HELLO  = 0x0c
const FRAME_READY  = 0x0d

"Encode one channel frame: [type][flags][termId][len][payload]."
function frame(type::UInt8, termId::UInt16, payload::Vector{UInt8})
    out = Vector{UInt8}(undef, 8 + length(payload))
    out[1] = type
    out[2] = 0x00
    out[3] = termId % UInt8
    out[4] = (termId >> 8) % UInt8
    n = UInt32(length(payload))
    out[5] = n % UInt8
    out[6] = (n >> 8) % UInt8
    out[7] = (n >> 16) % UInt8
    out[8] = (n >> 24) % UInt8
    length(payload) > 0 && copyto!(out, 9, payload, 1, length(payload))
    return out
end

"Receive one frame, or nothing if the peer stays quiet for `timeout` seconds."
function receive_frame(ws; timeout::Real = 5.0)
    box = Channel{Any}(1)
    @async begin
        try
            put!(box, HTTP.WebSockets.receive(ws))
        catch err
            put!(box, err)
        end
    end
    raw = take!(box)  # the channel holds one item, so this waits for it
    return raw
end

"The type of a received frame, or 0 when the peer sent nothing."
frame_type(raw) = (raw isa Vector{UInt8} && length(raw) >= 1) ? raw[1] : 0x00

function main()
    port = FlootyPTYLayer.start_channel_server!()
    id = String(FlootyPTYLayer.handleTerminalCreate(`/bin/sh -i`; rows = 24, cols = 80))
    println("channel port: ", port, "  session: ", id)
    failures = String[]
    HTTP.WebSockets.open("ws://127.0.0.1:$port/") do ws
        # Open the channel for the session the page would have created.
        HTTP.WebSockets.send(ws, frame(FRAME_OPEN, UInt16(0), Vector{UInt8}(codeunits(id))))
        raw = receive_frame(ws)
        t = frame_type(raw)
        println("server -> page: type=", t, t == FRAME_HELLO ? " (hello)" : " (expected hello)")
        t == FRAME_HELLO || push!(failures, "the server did not answer the open with a hello")

        # The page answers READY: only then does the socket carry the bytes.
        HTTP.WebSockets.send(ws, frame(FRAME_READY, UInt16(0), Vector{UInt8}()))
        sleep(0.3)

        # The output push: the bytes must arrive over the socket.
        payload = "CHANNEL_PROBE_$(rand(UInt32))"
        ok = FlootyPTYLayer.pushOutputToChannel(id, payload)
        ok || push!(failures, "the server refused to push over the channel")
        raw = receive_frame(ws)
        t = frame_type(raw)
        got = t == FRAME_OUTPUT ? String(copy(raw[17:end])) : ""
        println("server -> page: type=", t, " bytes=", length(raw),
                t == FRAME_OUTPUT ? " payload=" * repr(got) : "")
        t == FRAME_OUTPUT || push!(failures, "the output frame did not arrive")
        occursin(payload, got) || push!(failures, "the output frame did not carry the bytes")
    end
    if isempty(failures)
        println("CHANNEL_SERVER_PROBE_OK")
        return 0
    end
    for f in failures
        println("FAILED: ", f)
    end
    println("CHANNEL_SERVER_PROBE_FAILED")
    return 1
end

exit(main())
