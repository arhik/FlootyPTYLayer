// FlootyTerminal core — the browser owns the terminal.
//
// The model (xterm.js today, a WASM VT core in Phase 2) and the renderer
// live HERE, in the browser. The server owns the PTY and moves bytes. That
// split is terax-ai's shape: the native side never parses VT, and the
// browser never blocks on the server.
//
// The channel is one binary WebSocket, both directions:
//
//   frame: [type:1][flags:1][termId:2 LE][len:4 LE][payload]
//
//   OUTPUT  0x01  server -> browser   [u64 offset][raw PTY bytes]
//   ACK    0x02  browser -> server   [u64 offset] (cumulative)
//   INPUT  0x03  browser -> server   raw keystrokes
//   RESIZE 0x04  browser -> server   [u16 cols][u16 rows]
//   OPEN   0x05  browser -> server   open a terminal
//   OPENED 0x06  server -> browser   the new terminal id
//   CLOSE  0x07  browser -> server   close a terminal
//   EXIT   0x08  server -> browser   the PTY exited
//   CLASS  0x09  browser -> server   [u8 presentation class]
//   PING   0x0a  server -> browser   keepalive
//   PONG   0x0b  browser -> server   keepalive answer
//
// Rules borrowed from terax-ai (src-tauri/src/modules/pty):
//   * the byte OFFSET in every data frame lets the browser detect a gap
//     instead of silently losing bytes;
//   * the browser ACKs what it consumed, and the server keeps at most one
//     MiB in flight (credit), so a slow client throttles the sender rather
//     than growing an unbounded queue;
//   * the browser reports its presentation class, and the server picks the
//     coalescing deadline: 4 ms focused, 16 ms visible, 100 ms hidden,
//     250 ms occluded.
(function (global) {
    'use strict';

    var FRAME = {
        OUTPUT: 0x01, ACK: 0x02, INPUT: 0x03, RESIZE: 0x04, OPEN: 0x05,
        OPENED: 0x06, CLOSE: 0x07, EXIT: 0x08, CLASS: 0x09, PING: 0x0a, PONG: 0x0b,
        HELLO: 0x0c, READY: 0x0d
    };
    var CLASS = { FOCUSED: 0x00, VISIBLE: 0x01, HIDDEN: 0x02, OCCLUDED: 0x03 };
    var HEADER = 8;

    // How much of the incoming stream we hand to the model at once. xterm's
    // own write queue slices further with a time budget; this keeps a huge
    // burst from monopolising one task.
    var PARSE_SLICE_BYTES = 32 * 1024;

    function encode(type, termId, payload) {
        var p = payload || new Uint8Array(0);
        var out = new Uint8Array(HEADER + p.length);
        var view = new DataView(out.buffer);
        out[0] = type;
        out[1] = 0;
        view.setUint16(2, termId, true);
        view.setUint32(4, p.length, true);
        out.set(p, HEADER);
        return out;
    }

    function decode(buffer) {
        if (!buffer || buffer.byteLength < HEADER) return null;
        var view = new DataView(buffer);
        var type = view.getUint8(0);
        var termId = view.getUint16(2, true);
        var len = view.getUint32(4, true);
        if (buffer.byteLength < HEADER + len) return null;
        return { type: type, termId: termId,
                 payload: new Uint8Array(buffer, HEADER, len) };
    }

    function u64(bytes, offset) {
        // Little endian, two 32-bit halves.
        var lo = (bytes[offset] | (bytes[offset + 1] << 8) |
                  (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
        var hi = (bytes[offset + 4] | (bytes[offset + 5] << 8) |
                  (bytes[offset + 6] << 16) | (bytes[offset + 7] << 24)) >>> 0;
        return hi * 4294967296 + lo;
    }

    function writeU64(value) {
        var out = new Uint8Array(8);
        var lo = value >>> 0;
        var hi = Math.floor(value / 4294967296);
        out[0] = lo & 0xff; out[1] = (lo >>> 8) & 0xff;
        out[2] = (lo >>> 16) & 0xff; out[3] = (lo >>> 24) & 0xff;
        out[4] = hi & 0xff; out[5] = (hi >>> 8) & 0xff;
        out[6] = (hi >>> 16) & 0xff; out[7] = (hi >>> 24) & 0xff;
        return out;
    }

    /**
     * The terminal core: model + renderer + channel client.
     *
     * opts: { term, wsPort, onExit, onBytes }
     */
    function TerminalCore(opts) {
        this.term = opts.term;
        this.wsPort = opts.wsPort;
        this.onExit = opts.onExit || function () {};
        this.onBytes = opts.onBytes || function () {};
        this.onOutput = opts.onOutput || null;
        // Called when the server confirmed the channel (the HELLO/READY
        // handshake): the page sends whatever it held until then.
        this.onReady = opts.onReady || null;
        // Set once the server confirmed (HELLO/READY) that this socket may
        // carry the terminal's bytes.
        this.ready = false;
        this.ws = null;
        this.termId = 0;
        // A session the page already created (the control plane made it): the
        // channel then carries THAT session's bytes instead of making a new
        // terminal.
        this.sessionId = opts.sessionId || '';
        this.expectedOffset = 0;   // the next byte offset we expect
        this.bytesIn = 0;
        this.bytesOut = 0;
        this.gaps = 0;
        this.pendingAck = 0;
    }

    TerminalCore.prototype.connect = function () {
        var self = this;
        var url = 'ws://127.0.0.1:' + this.wsPort + '/';
        this.ws = new WebSocket(url);
        this.ws.binaryType = 'arraybuffer';
        this.ws.onopen = function () {
            // An empty id asks the server for a NEW terminal; a named one
            // binds the channel to the session the page already created.
            var id = self.sessionId ?
                new TextEncoder().encode(self.sessionId) : new Uint8Array(0);
            self.send(FRAME.OPEN, 0, id);
            self.reportPresentation();
        };
        this.ws.onmessage = function (ev) {
            var frame = decode(ev.data);
            if (frame) self.onFrame(frame);
        };
        this.ws.onclose = function (ev) {
            try { if (window.flootyDebug) window.flootyDebug('channel closed code=' + (ev && ev.code) + ' reason=' + (ev && ev.reason)); } catch (e) {}
            // Tell the server: the bytes must go back over the eval path
            // instead of into a dead socket.
            try {
                if (window.flootyChannelClosed && self.sessionId) {
                    window.flootyChannelClosed(JSON.stringify({ terminal_id: self.sessionId }));
                }
            } catch (e) { }
            // The server went away: show it instead of a dead pane. (Not every
            // model has writeln — xterm.js does, the ShadowTerm core does not.)
            try {
                if (typeof self.term.writeln === 'function') {
                    self.term.writeln('\r\n[terminal channel closed]');
                } else {
                    self.term.write('\r\n[terminal channel closed]\r\n');
                }
            } catch (e) { }
        };
        return this;
    };

    // Is the channel usable RIGHT NOW? A socket that never opened (an
    // occluded webview can stall the handshake) must not swallow the
    // keystrokes: the RPC path is the fallback.
    TerminalCore.prototype.isLive = function () {
        return !!(this.ws && this.ws.readyState === 1 && this.ready);
    };

    TerminalCore.prototype.send = function (type, termId, payload) {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
        this.ws.send(encode(type, termId, payload));
        return true;
    };

    TerminalCore.prototype.onFrame = function (frame) {
        var p = frame.payload;
        switch (frame.type) {
            case FRAME.OPENED:
                this.termId = frame.termId;
                this.expectedOffset = 0;
                break;
            case FRAME.OUTPUT: {
                var offset = u64(p, 0);
                var bytes = p.subarray(8);
                if (offset !== this.expectedOffset) {
                    // A gap: the server skipped bytes. Report it instead of
                    // rendering a screen with a hole in it.
                    this.gaps++;
                    this.expectedOffset = offset;
                }
                this.expectedOffset += bytes.length;
                this.bytesIn += bytes.length;
                this.feed(bytes);
                this.ack();
                break;
            }
            case FRAME.EXIT:
                this.onExit(frame.termId);
                break;
            case FRAME.PING:
                this.send(FRAME.PONG, frame.termId, new Uint8Array(0));
                break;
            case FRAME.HELLO:
                // The server asks whether this socket may carry the bytes.
                // Only after this round trip does it use the channel, so a
                // socket that never works cannot swallow the output.
                this.ready = true;
                this.send(FRAME.READY, frame.termId, new Uint8Array(0));
                if (this.onReady) {
                    try { this.onReady(); } catch (e) {}
                }
                break;
            default:
                break;
        }
    };

    // Hand the bytes to the model.
    // The page can take over (onOutput): an app that already has its own
    // per-tab output handling (the handshake buffering, the fan-out over the
    // tabs bound to one session) wants the RAW bytes, not a direct model
    // write.
    TerminalCore.prototype.feed = function (bytes) {
        if (bytes.length === 0) return;
        if (this.onOutput) {
            this.onOutput(bytes);
        } else {
            var i = 0;
            while (i < bytes.length) {
                var end = Math.min(i + PARSE_SLICE_BYTES, bytes.length);
                this.term.write(bytes.subarray(i, end));
                i = end;
            }
        }
        this.onBytes(this.bytesIn);
    };

    TerminalCore.prototype.ack = function () {
        // Cumulative ack: the server may only have INFLIGHT_WINDOW bytes
        // outstanding, so this is what keeps the stream moving.
        this.pendingAck = this.expectedOffset;
        if (!this._ackScheduled) {
            var self = this;
            this._ackScheduled = true;
            setTimeout(function () {
                self._ackScheduled = false;
                if (self.pendingAck > 0) {
                    self.send(FRAME.ACK, self.termId, writeU64(self.pendingAck));
                }
            }, 8);
        }
    };

    TerminalCore.prototype.input = function (data) {
        var bytes = new TextEncoder().encode(data);
        this.bytesOut += bytes.length;
        this.send(FRAME.INPUT, this.termId, bytes);
    };

    // Raw bytes (the mouse reports): the same frame, without the encoding.
    TerminalCore.prototype.inputBytes = function (bytes) {
        this.bytesOut += bytes.length;
        this.send(FRAME.INPUT, this.termId, bytes);
    };

    TerminalCore.prototype.resize = function (cols, rows) {
        var p = new Uint8Array(4);
        new DataView(p.buffer).setUint16(0, cols, true);
        new DataView(p.buffer).setUint16(2, rows, true);
        this.send(FRAME.RESIZE, this.termId, p);
    };

    TerminalCore.prototype.close = function () {
        this.send(FRAME.CLOSE, this.termId, new Uint8Array(0));
    };

    // The presentation class decides the server's coalescing deadline.
    TerminalCore.prototype.reportPresentation = function () {
        var cls;
        if (document.visibilityState === 'hidden') {
            cls = document.hasFocus() ? CLASS.HIDDEN : CLASS.OCCLUDED;
        } else if (document.hasFocus()) {
            cls = CLASS.FOCUSED;
        } else {
            cls = CLASS.VISIBLE;
        }
        this.send(FRAME.CLASS, this.termId, new Uint8Array([cls]));
        return cls;
    };

    TerminalCore.prototype.stats = function () {
        return { bytesIn: this.bytesIn, bytesOut: this.bytesOut, gaps: this.gaps,
                 termId: this.termId };
    };

    global.FlootyTerminalCore = {
        TerminalCore: TerminalCore,
        FRAME: FRAME,
        CLASS: CLASS,
        encode: encode,
        decode: decode
    };
})(window);
