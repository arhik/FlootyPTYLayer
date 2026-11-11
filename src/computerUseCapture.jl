function _captureMainDisplay()
    # CGWindowListCreateImage is a public API since 10.5._kCGWindowListOptionOnScreenOnly captures
    # the screen as it is actually laid out; use kCGNullWindowID + kCGWindowListOptionAll to grab
    # the whole desktop (best-effort UX snapshots).
    image = ccall(:CGWindowListCreateImage, Ptr{Cvoid},
                  (Cint, Cint, Cuint, Cint),
                  -1, 1, 0, 0) # NULL_RECT, kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageDefault
    return image
end

function _cgimageToPng(image::Ptr{Cvoid})
    # We can't easily round-trip CGImage -> PNG without CFBridging types; fall back to base64
    # of a trivial marker so callers always get a binary blob — the real PNG encoder lives in
    # the page (canvas.toDataURL) and overrides this for UI screenshots.
    return UInt8[] # placeholder until native PNG path is wired via CoreFoundation APIs
end
