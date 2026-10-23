# channelProbe.jl — the app's data plane: are the PTY bytes travelling over
# the binary channel (and how fast)?
#
# The app pushes the PTY's output to the page as a per-chunk JavaScript eval
# and takes every keystroke through a JSON-RPC round trip. When the page has
# opened a data-plane channel for the session, the bytes go over ONE binary
# WebSocket instead (raw bytes, no JSON).
#
# This probe launches the REAL UI, checks that the channel is open, and
# measures the keystroke-to-echo round trip over it.
#
#   julia --startup-file=no --project=. test/channelProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer
using Logging
using Webviews

mutable struct CaptureLogger <: Logging.AbstractLogger
    lines::Vector{String}
end
CaptureLogger() = CaptureLogger(String[])
Logging.min_enabled_level(::CaptureLogger) = Logging.Debug
Logging.shouldlog(::CaptureLogger, args...) = true
function Logging.handle_message(l::CaptureLogger, level, msg, mod, group, id,
                                file, line; kwargs...)
    push!(l.lines, string(msg))
    return nothing
end

cap = CaptureLogger()
wv = FlootyPTYLayer.launchTerminalUI()
worker = @async begin
    # Wait for the page (it pushes the renderer report itself).
    deadline = time() + 30
    while time() < deadline && FlootyPTYLayer.gpuRendererReport() === nothing
        sleep(0.2)
    end
    sleep(1.5)

    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ids = Object.keys(window.flootyChannels || {});
          var out = [];
          for (var i = 0; i < ids.length; i++) {
            var c = window.flootyChannels[ids[i]];
            out.push(ids[i] + ' ws=' + (c.ws ? c.ws.readyState : 'none') +
                     ' in=' + c.bytesIn + ' out=' + c.bytesOut);
          }
          window.flootyDebug('CHANNELS ' + out.join(' | '));
        })()
        """)
    end
    sleep(1.0)

    # A raw socket to the channel port: is the server accepting connections
    # at all, and does the socket stay open?
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var port = window.FLOOTY_TERMINAL && window.FLOOTY_TERMINAL.channelPort;
          window.flootyDebug('CHANNELPORT ' + port);
          if (!port) return;
          var ws = new WebSocket('ws://127.0.0.1:' + port + '/');
          ws.binaryType = 'arraybuffer';
          ws.onopen = function () { window.flootyDebug('RAW open'); };
          ws.onclose = function (e) { window.flootyDebug('RAW close code=' + e.code + ' reason=' + e.reason); };
          ws.onerror = function (e) { window.flootyDebug('RAW error'); };
        })()
        """)
    end
    sleep(2.0)

    # What did the SERVER bind? (The page's view and the server's must agree.)
    lock(FlootyPTYLayer.CHANNEL_LOCK) do
        for (k, b) in FlootyPTYLayer.CHANNEL_SESSIONS
            println("SERVER BINDING: ", k, " offset=", b.offset, " acked=", b.acked)
        end
        println("SERVER bindings: ", length(FlootyPTYLayer.CHANNEL_SESSIONS))
    end
    println("PAGE sessions: ", join(collect(keys(FlootyPTYLayer.ACTIVE_TERMINALS)), ","))
    for (id, e) in FlootyPTYLayer.ACTIVE_TERMINALS
        println("ENTRY ", id, " exited=", e.exited, " collected=",
                length(FlootyPTYLayer.collectedText(e)), " livePush=", e.livePush)
    end
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var t = null;
          for (var id in window.terminals) { t = window.terminals[id].term; break; }
          window.flootyDebug('PAGE term=' + (t ? 'yes' : 'no'));
        })()
        """)
    end
    sleep(1.0)

    # The keystroke-to-echo round trip over the channel.
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var t = null;
          for (var id in window.flootyTerminals) { t = window.flootyTerminals[id].term; break; }
          if (!t) { window.flootyDebug('LAT no-term'); return; }
          var ch = null;
          for (var id in window.flootyChannels) { ch = window.flootyChannels[id]; break; }
          window.flootyDebug('LAT channel ready=' + (ch ? ch.ready : 'none') +
                             ' live=' + (ch ? ch.isLive() : 'none'));
          var pending = 0;
          t.onWriteParsed(function () {
            if (pending > 0) { window.flootyDebug('LAT ' + (performance.now() - pending).toFixed(1)); pending = 0; }
          });
          var ta = document.querySelector('.xterm-helper-textarea');
          pending = performance.now();
          ta.value = 'q';
          ta.dispatchEvent(new InputEvent('input', {bubbles: true, data: 'q', inputType: 'insertText'}));
        })()
        """)
    end
    sleep(3.0)

    # The channel's counters after the round trip: the echo must have come
    # over the socket, not over the eval path.
    Webviews.dispatch(wv) do
        Webviews.eval!(wv, """
        (function () {
          var ids = Object.keys(window.flootyChannels || {});
          var out = [];
          for (var i = 0; i < ids.length; i++) {
            var c = window.flootyChannels[ids[i]];
            out.push(ids[i] + ' ws=' + (c.ws ? c.ws.readyState : 'none') +
                     ' ready=' + (c.ready ? 'yes' : 'no') +
                     ' in=' + c.bytesIn + ' out=' + c.bytesOut);
          }
          window.flootyDebug('CHANNELS-AFTER ' + out.join(' | '));
        })()
        """)
    end
    sleep(1.0)

    for l in cap.lines
        println("LOG: ", l)
    end
    try; Webviews.close(wv); catch; end
end

Logging.with_logger(cap) do
    FlootyPTYLayer.runEventLoopAndTeardown!(wv)
end
wait(worker)
println("CHANNEL_PROBE_DONE")
