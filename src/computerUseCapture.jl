# Wk native screenshot helper for the computer-use server.
# Captures the wk window via CoreGraphics and encodes it as PNG.

const CGFloat = @static Sys.WORD_SIZE == 64 ? Float64 : Float32
struct CGPoint
    x::CGFloat
    y::CGFloat
end
struct CGSize
    width::CGFloat
    height::CGFloat
end
struct CGRect
    origin::CGPoint
    size::CGSize
end
CGRect(x, y, w, h) = CGRect(CGPoint(x, y), CGSize(w, h))

const CGWindowListOptionIncludingWindow = Cuint(8)   # kCGWindowListOptionIncludingWindow
const kCGWindowImageDefault = Cuint(0)               # kCGWindowImageDefault
const NSMutableDataCls = "NSMutableData"
const NSStringCls = "NSString"
const NSWindowCls = "NSWindow"

_sel(name::AbstractString) = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), name)
_cls(name::AbstractString) = ccall(:objc_getClass, Ptr{Cvoid}, (Cstring,), name)
function _wk_window_handle(wv)
    wh = try
        Webviews.window_handle(wv)
    catch err
        @debug "computer-use: window_handle failed" exception = err
        return nothing
    end
    wh == C_NULL && return nothing
    return wh
end

function _window_number(wh::Ptr{Cvoid})
    wh == C_NULL && return nothing
    num = ccall(:objc_msgSend, Culong, (Ptr{Cvoid}, Ptr{Cvoid}),
                wh, _sel("windowNumber"))
    return UInt32(num & 0xffffffff)
end

function _capture_window(win_number::UInt32)
    image = ccall(:CGWindowListCreateImage, Ptr{Cvoid},
                  (CGRect, Cuint, UInt32, Cuint),
                  CGRect(0.0, 0.0, 0.0, 0.0),   # CGRectNull
                  CGWindowListOptionIncludingWindow,
                  win_number,
                  kCGWindowImageDefault)
    return image == C_NULL ? nothing : image
end

function _cgimage_to_png(image::Ptr{Cvoid})
    data = ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}),
                 _cls(NSMutableDataCls), _sel("alloc"))
    data == C_NULL && return nothing
    data = ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), data, _sel("init"))

    dest = ccall(:CGImageDestinationCreateWithData, Ptr{Cvoid},
                 (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}),
                 data,
                 ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring),
                       _cls(NSStringCls), _sel("stringWithUTF8String:"), "public.png"),
                 1,
                 C_NULL)
    dest == C_NULL && return nothing

    add_ok = ccall(:CGImageDestinationAddImage, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                  dest, image, C_NULL)
    fin_ok = ccall(:CGImageDestinationFinalize, Cint, (Ptr{Cvoid},), dest)
    ccall(:CFRelease, Cvoid, (Ptr{Cvoid},), dest)

    if add_ok == 0 || fin_ok == 0
        @debug "computer-use: CGImageDestination step failed" add=add_ok final=fin_ok
        return nothing
    end

    nsString = ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t),
                     data, _sel("base64EncodedStringWithOptions:"), Csize_t(0))
    if nsString == C_NULL
        return nothing
    end
    utf8 = ccall(:objc_msgSend, Ptr{Cchar}, (Ptr{Cvoid}, Ptr{Cvoid}), nsString, _sel("UTF8String"))
    if utf8 == C_NULL
        return nothing
    end
    return unsafe_string(utf8)
end

function captureScreenshot(wv)
    wh = _wk_window_handle(wv)
    wh === nothing && return nothing
    num = _window_number(wh)
    num === nothing && return nothing
    image = _capture_window(num)
    image === nothing && return nothing
    png = _cgimage_to_png(image)
    ccall(:CGImageRelease, Cvoid, (Ptr{Cvoid},), image)
    return png
end
