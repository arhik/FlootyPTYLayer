# utf8CarryProbe.jl — a UTF-8 sequence split across PTY reads must not become U+FFFD.
# Observed live: juliaup progress-bar glyph arrived as 0xe2 | 0x94 0x81 and
# rendered as two replacement chars in the web terminal.
using FlootyPTYLayer
const F = FlootyPTYLayer

b = Vector{UInt8}(codeunits("━"))
c = F.Utf8Carry()
@assert F.decodeChunk!(c, b[1:1]) == ""          # lead byte held back
@assert F.decodeChunk!(c, b[2:3]) == "━"         # completed next chunk
@assert isempty(c.pending)

# Genuinely invalid bytes still become U+FFFD.
@assert F.decodeChunk!(F.Utf8Carry(), UInt8[0xff, 0x41]) == "\ufffdA"

# Whole valid text passes through untouched.
@assert F.decodeChunk!(F.Utf8Carry(), Vector{UInt8}(codeunits("ok ━ done"))) == "ok ━ done"

# Byte-at-a-time feeding reassembles the character.
c2 = F.Utf8Carry()
out = join(F.decodeChunk!(c2, [x]) for x in b)
@assert out == "━"
println("utf8CarryProbe: all assertions passed")
