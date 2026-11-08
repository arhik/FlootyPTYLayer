# divergence.jl — quantify how many screens the human's xterm and the agent's
# shadow model actually share. Both are fed the same PTY bytes; they should
# agree row-for-row, but two independent parsers drift on every opcode. This
# probe hashes both grids row-wise (and in aggregate) so the drift can be
# measured instead of argued about.
#
# Returns a NamedTuple:
#   matched   :: Bool    both grids are identical
#   rows      :: Int     number of rows compared (the winsize)
#   shadowHash:: UInt    combined hash of the shadow grid
#   pageHash  :: UInt    combined hash of the page grid (nothing if no report)
#   diffs     :: Vector{NamedTuple{(:row,:shadow,:page),Tuple{Int,String,String}}}

"Combined hash of a row-string vector (row order matters, trailing whitespace does not)."
function gridChecksum(lines::Vector{String})::UInt
    h = zero(UInt)
    for line in lines
        h = hash(hash(rstrip(String(line))), h)
    end
    return h
end

"Line-by-line comparison of the shadow screen and the latest page report."
function terminalDivergence(sess; maxAgeS::Real = 5.0)
    id = sessionIdFor(sess)
    isempty(id) && return (matched = false, rows = 0, shadowHash = UInt(0),
                           pageHash = nothing, diffs = nothing,
                           reason = "no session id")
    entry = getEntry(id)
    entry === nothing && return (matched = false, rows = 0, shadowHash = UInt(0),
                                 pageHash = nothing, diffs = nothing,
                                 reason = "not adopted")
    flushTerminalOutput!(sess)   # keep the report fresh
    shadow = shadowLines(entry)
    pageText = terminalBufferFor(sess; maxAgeS = maxAgeS)
    isempty(pageText) && return (matched = false, rows = length(shadow),
                                 shadowHash = gridChecksum(shadow),
                                 pageHash = nothing, diffs = nothing,
                                 reason = "no page report yet")
    pageLines = String[rstrip(String(l)) for l in split(pageText, '\n')]
    rows = length(shadow)
    shadowHash = gridChecksum(shadow)
    pageHash = gridChecksum(pageLines)
    diffs = NamedTuple{(:row, :shadow, :page), Tuple{Int, String, String}}[]
    for r in 1:rows
        s = rstrip(shadow[r])
        p = r <= length(pageLines) ? rstrip(pageLines[r]) : ""
        s == p || push!(diffs, (row = r, shadow = s, page = p))
    end
    return (matched = isempty(diffs), rows = rows, shadowHash = shadowHash,
            pageHash = pageHash, diffs = diffs, reason = "ok")
end
