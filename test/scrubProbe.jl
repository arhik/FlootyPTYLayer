import FlootyPTYLayer

# Regression: a sentinel line cut off BEFORE its trailing newline used to hit
# `something(match(...), "").match` -> FieldError (String has no field 'match').
# That is exactly the shape the agent-loop ACTION RESULT excerpt can produce.

puaMarker = string(Char(0xf0a7))

function assertEqual(actual::AbstractString, expected::AbstractString, label::AbstractString)
    if actual != expected
        println("FAIL[$label]: got $(repr(actual)), want $(repr(expected))")
        exit(1)
    end
end

# 1. Full sentinel line WITH newline: WHOLE line blanked (row kept),
# terminator preserved — blanking the entire row is the documented intent.
out = FlootyPTYLayer.scrubSentinelLines("julia> $(puaMarker)FLOOTY_EVAL_BEGIN e1\r\nx = 21\n")
assertEqual(out, "\r\nx = 21\n", "full-line-with-eol")

# 2. THE CRASH CASE: sentinel content with NO trailing newline.
out = FlootyPTYLayer.scrubSentinelLines("$(puaMarker)FLOOTY_EVAL_END e1")
assertEqual(out, "", "sentinel-no-eol")

# 3. Mixed: clean lines around a truncated sentinel fragment.
out = FlootyPTYLayer.scrubSentinelLines("ok line\nFLOOTY_EVAL_")
assertEqual(out, "ok line\n", "truncated-fragment")

# 4. Plain text passes through untouched.
plain = "julia> 1 + 1\n2\n"
assertEqual(FlootyPTYLayer.scrubSentinelLines(plain), plain, "passthrough")

# 5. CHUNK-BOUNDARY SPLITS of a sentinel line — each half arrives alone.
scrub = FlootyPTYLayer.SentinelScrubber()
part1 = FlootyPTYLayer.scrubForDisplay!(scrub,
    "julia> $(puaMarker)println('" * "FLOOTY_EV")
assertEqual(part1, "", "split-tag-hold-first-half")
part2 = FlootyPTYLayer.scrubForDisplay!(
    scrub, "AL_BEGIN:\", \"eval000001\")\r\nx = 21\n")
if occursin("FLOOTY", part2) || occursin(puaMarker, part2)
    println("FAIL[split-tag-second-half-scrubbed]: got $(repr(part2))")
    exit(1)
end
# The orphan half is on its OWN line: blanked but the \r\n row is kept
# (row-count preservation contract).
assertEqual(part2, "\r\nx = 21\n", "split-tag-second-half-scrubbed")

# 6. Trailing partial line ending EXACTLY mid-tag is held, not flushed.
scrub2 = FlootyPTYLayer.SentinelScrubber()
held = FlootyPTYLayer.scrubForDisplay!(scrub2, "ok\njulia> FLOOTY_E")
assertEqual(held, "ok\n", "partial-tag-held")

# 7. Ordinary partial prompt text still flushes immediately (no over-hold).
scrub3 = FlootyPTYLayer.SentinelScrubber()
flushed = FlootyPTYLayer.scrubForDisplay!(scrub3, "julia> fib(")
assertEqual(flushed, "julia> fib(", "normal-partial-flushed")

println("SCRUB_PROBE_OK")
