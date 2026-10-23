"""ShadowTerminal: server-side terminal MODEL fed the same PTY bytes as the page.
Not a renderer. Source of truth for "what is on screen" so agent snapshots,
headless tests and attach snapshots need not round-trip through the browser DOM.
"""
module ShadowTerminal

using ..ShadowTerm
using ..ShadowTerm: Parser, Grid, Cell, feed!, getparam,
    PRINT, EXECUTE, CSI_DISPATCH, ESC_DISPATCH, OSC_DISPATCH, NONE,
    DEFAULT_COLOR, FLAG_BOLD, FLAG_DIM, FLAG_ITALIC, FLAG_UNDERLINE,
    FLAG_BLINK, FLAG_REVERSE, FLAG_INVISIBLE, FLAG_STRIKETHROUGH,
    WIDTH_NARROW, WIDTH_WIDE, WIDTH_CONTINUATION,
    setcell!, getcell, clear!, clearrow!, clearRange!,
    scrollUp!, scrollDown!, deletecells!, insertcells!, reset!

export ShadowTerm, shadowFeed!, shadowResize!, shadowText, shadowLines,
    shadowCursor, shadowClear!

mutable struct ShadowTerm
    parser::Parser
    grid::Grid
    cols::Int
    rows::Int
    cur_row::Int
    cur_col::Int
    wrap_pending::Bool
    saved_row::Int
    saved_col::Int
    fg::UInt16
    bg::UInt16
    flags::UInt8
    scroll_top::Int
    scroll_bottom::Int
    autowrap::Bool
    cursor_visible::Bool
    title::String
end

function ShadowTerm(cols::Integer = 80, rows::Integer = 24)
    c = max(1, Int(cols)); r = max(1, Int(rows))
    ShadowTerm(Parser(), Grid(c, r), c, r, 0, 0, false, 0, 0,
               DEFAULT_COLOR, DEFAULT_COLOR, 0x00,
               0, r - 1, true, true, "")
end

blank(t::ShadowTerm) = Cell(char = UInt32(0x20), fg = t.fg, bg = t.bg,
                            flags = t.flags, width = WIDTH_NARROW)

function shadowClear!(t::ShadowTerm)
    clear!(t.grid)
    t.cur_row = 0; t.cur_col = 0
    t.wrap_pending = false
    return t
end

function shadowResize!(t::ShadowTerm, cols::Integer, rows::Integer)
    c = max(1, Int(cols)); r = max(1, Int(rows))
    (c == t.cols && r == t.rows) && return t
    t.cols = c; t.rows = r
    reset!(t.grid, c, r)
    t.cur_row = clamp(t.cur_row, 0, r - 1)
    t.cur_col = clamp(t.cur_col, 0, c - 1)
    t.scroll_top = 0; t.scroll_bottom = r - 1
    t.wrap_pending = false
    return t
end

function scrollregion!(t::ShadowTerm, n::Integer)
    n <= 0 && return
    scrollUp!(t.grid, t.scroll_top, t.scroll_bottom, n, blank(t))
end

function linefeed!(t::ShadowTerm)
    if t.cur_row == t.scroll_bottom
        scrollregion!(t, 1)
    elseif t.cur_row < t.rows - 1
        t.cur_row += 1
    end
    t.wrap_pending = false
end

function carriagereturn!(t::ShadowTerm)
    t.cur_col = 0
    t.wrap_pending = false
end

function putchar!(t::ShadowTerm, ch::UInt32, width::Integer)
    if t.wrap_pending && t.autowrap
        carriagereturn!(t); linefeed!(t)
    end
    if width == 2 && t.cur_col >= t.cols - 1
        if t.autowrap
            carriagereturn!(t); linefeed!(t)
        else
            return
        end
    end
    setcell!(t.grid, t.cur_row, t.cur_col,
             Cell(char = ch, fg = t.fg, bg = t.bg, flags = t.flags,
                  width = width == 2 ? WIDTH_WIDE : WIDTH_NARROW))
    if width == 2 && t.cur_col + 1 < t.cols
        setcell!(t.grid, t.cur_row, t.cur_col + 1,
                 Cell(char = UInt32(0), fg = t.fg, bg = t.bg,
                      flags = t.flags, width = WIDTH_CONTINUATION))
    end
    t.cur_col += width
    if t.cur_col >= t.cols
        t.cur_col = t.cols - 1
        t.wrap_pending = true
    end
end

function sgr!(t::ShadowTerm, p::Parser)
    n = p.param_count
    if n == 0
        t.fg = DEFAULT_COLOR; t.bg = DEFAULT_COLOR; t.flags = 0x00
        return
    end
    i = 0
    while i < n
        v = Int(getparam(p, i, 0))
        if v == 0
            t.fg = DEFAULT_COLOR; t.bg = DEFAULT_COLOR; t.flags = 0x00
        elseif v == 1
            t.flags |= FLAG_BOLD
        elseif v == 2
            t.flags |= FLAG_DIM
        elseif v == 3
            t.flags |= FLAG_ITALIC
        elseif v == 4
            t.flags |= FLAG_UNDERLINE
        elseif v == 5
            t.flags |= FLAG_BLINK
        elseif v == 7
            t.flags |= FLAG_REVERSE
        elseif v == 8
            t.flags |= FLAG_INVISIBLE
        elseif v == 9
            t.flags |= FLAG_STRIKETHROUGH
        elseif v == 22
            t.flags &= ~(FLAG_BOLD | FLAG_DIM)
        elseif v == 23
            t.flags &= ~FLAG_ITALIC
        elseif v == 24
            t.flags &= ~FLAG_UNDERLINE
        elseif v == 25
            t.flags &= ~FLAG_BLINK
        elseif v == 27
            t.flags &= ~FLAG_REVERSE
        elseif v == 28
            t.flags &= ~FLAG_INVISIBLE
        elseif v == 29
            t.flags &= ~FLAG_STRIKETHROUGH
        elseif 30 <= v <= 37
            t.fg = UInt16(v - 30)
        elseif v == 39
            t.fg = DEFAULT_COLOR
        elseif 40 <= v <= 47
            t.bg = UInt16(v - 40)
        elseif v == 49
            t.bg = DEFAULT_COLOR
        elseif 90 <= v <= 97
            t.fg = UInt16(v - 90 + 8)
        elseif 100 <= v <= 107
            t.bg = UInt16(v - 100 + 8)
        end
        i += 1
    end
end

function csi!(t::ShadowTerm, p::Parser)
    final = Char(p.execute_byte)
    n = p.param_count
    p1 = Int(getparam(p, 0, 1))
    p2 = Int(getparam(p, 1, 1))
    if final == Char(0x41)
        t.cur_row = max(t.scroll_top, t.cur_row - max(1, p1)); t.wrap_pending = false
    elseif final == Char(0x42)
        t.cur_row = min(t.scroll_bottom, t.cur_row + max(1, p1)); t.wrap_pending = false
    elseif final == Char(0x43)
        t.cur_col = min(t.cols - 1, t.cur_col + max(1, p1)); t.wrap_pending = false
    elseif final == Char(0x44)
        t.cur_col = max(0, t.cur_col - max(1, p1)); t.wrap_pending = false
    elseif final == Char(0x45)
        t.cur_row = min(t.scroll_bottom, t.cur_row + max(1, p1)); t.cur_col = 0; t.wrap_pending = false
    elseif final == Char(0x46)
        t.cur_row = max(t.scroll_top, t.cur_row - max(1, p1)); t.cur_col = 0; t.wrap_pending = false
    elseif final == Char(0x47) || final == Char(0x60)
        t.cur_col = clamp(p1 - 1, 0, t.cols - 1); t.wrap_pending = false
    elseif final == Char(0x64)
        t.cur_row = clamp(p1 - 1, 0, t.rows - 1); t.wrap_pending = false
    elseif final == Char(0x48) || final == Char(0x66)
        t.cur_row = clamp(p1 - 1, 0, t.rows - 1)
        t.cur_col = clamp(p2 - 1, 0, t.cols - 1)
        t.wrap_pending = false
    elseif final == Char(0x4A)
        mode = n == 0 ? 0 : Int(getparam(p, 0, 0))
        if mode == 0
            clearRange!(t.grid, t.cur_row, t.cur_col, t.cols, blank(t))
            for r in (t.cur_row + 1):(t.rows - 1)
                clearrow!(t.grid, r, blank(t))
            end
        elseif mode == 1
            for r in 0:(t.cur_row - 1)
                clearrow!(t.grid, r, blank(t))
            end
            clearRange!(t.grid, t.cur_row, 0, t.cur_col + 1, blank(t))
        else
            clear!(t.grid)
        end
    elseif final == Char(0x4B)
        mode = n == 0 ? 0 : Int(getparam(p, 0, 0))
        if mode == 0
            clearRange!(t.grid, t.cur_row, t.cur_col, t.cols, blank(t))
        elseif mode == 1
            clearRange!(t.grid, t.cur_row, 0, t.cur_col + 1, blank(t))
        else
            clearrow!(t.grid, t.cur_row, blank(t))
        end
    elseif final == Char(0x4C)
        scrollDown!(t.grid, t.cur_row, t.scroll_bottom, max(1, p1), blank(t))
    elseif final == Char(0x4D)
        scrollUp!(t.grid, t.cur_row, t.scroll_bottom, max(1, p1), blank(t))
    elseif final == Char(0x50)
        deletecells!(t.grid, t.cur_row, t.cur_col, max(1, p1), blank(t))
    elseif final == Char(0x40)
        insertcells!(t.grid, t.cur_row, t.cur_col, max(1, p1), blank(t))
    elseif final == Char(0x58)
        clearRange!(t.grid, t.cur_row, t.cur_col,
                    min(t.cols, t.cur_col + max(1, p1)), blank(t))
    elseif final == Char(0x53)
        scrollregion!(t, max(1, p1))
    elseif final == Char(0x54)
        scrollDown!(t.grid, t.scroll_top, t.scroll_bottom, max(1, p1), blank(t))
    elseif final == Char(0x72)
        top = clamp(p1 - 1, 0, t.rows - 1)
        bot = clamp(p2 - 1, 0, t.rows - 1)
        if top < bot
            t.scroll_top = top; t.scroll_bottom = bot
            t.cur_row = top; t.cur_col = 0
        end
    elseif final == Char(0x73)
        t.saved_row = t.cur_row; t.saved_col = t.cur_col
    elseif final == Char(0x75)
        t.cur_row = clamp(t.saved_row, 0, t.rows - 1)
        t.cur_col = clamp(t.saved_col, 0, t.cols - 1)
    elseif final == Char(0x6D)
        sgr!(t, p)
    elseif final == Char(0x68) || final == Char(0x6C)
        on = final == Char(0x68)
        for k in 0:(n - 1)
            m = Int(getparam(p, k, 0))
            m == 7 && (t.autowrap = on)
            m == 25 && (t.cursor_visible = on)
        end
    end
    return
end

function esc!(t::ShadowTerm, p::Parser)
    b = p.execute_byte
    if b == UInt8(0x37)
        t.saved_row = t.cur_row; t.saved_col = t.cur_col
    elseif b == UInt8(0x38)
        t.cur_row = clamp(t.saved_row, 0, t.rows - 1)
        t.cur_col = clamp(t.saved_col, 0, t.cols - 1)
    elseif b == UInt8(0x44)
        linefeed!(t)
    elseif b == UInt8(0x45)
        carriagereturn!(t); linefeed!(t)
    elseif b == UInt8(0x4D)
        if t.cur_row == t.scroll_top
            scrollDown!(t.grid, t.scroll_top, t.scroll_bottom, 1, blank(t))
        elseif t.cur_row > 0
            t.cur_row -= 1
        end
    elseif b == UInt8(0x63)
        shadowClear!(t)
        t.fg = DEFAULT_COLOR; t.bg = DEFAULT_COLOR; t.flags = 0x00
        t.autowrap = true; t.cursor_visible = true
        t.scroll_top = 0; t.scroll_bottom = t.rows - 1
    end
    return
end

function shadowFeed!(t::ShadowTerm, bytes::AbstractVector{UInt8})
    for b in bytes
        act = feed!(t.parser, b)
        if act == PRINT
            putchar!(t, t.parser.print_char, 1)
        elseif act == EXECUTE
            e = t.parser.execute_byte
            if e == 0x0A || e == 0x0B || e == 0x0C
                linefeed!(t)
            elseif e == 0x0D
                carriagereturn!(t)
            elseif e == 0x08
                t.cur_col = max(0, t.cur_col - 1); t.wrap_pending = false
            elseif e == 0x09
                t.cur_col = min(t.cols - 1, (div(t.cur_col, 8) + 1) * 8)
            end
        elseif act == CSI_DISPATCH
            csi!(t, t.parser)
        elseif act == ESC_DISPATCH
            esc!(t, t.parser)
        end
    end
    return t
end

function shadowFeed!(t::ShadowTerm, s::AbstractString)
    shadowFeed!(t, Vector{UInt8}(codeunits(s)))
end

function shadowLines(t::ShadowTerm)
    out = Vector{String}(undef, t.rows)
    for r in 0:(t.rows - 1)
        io = IOBuffer()
        for c in 0:(t.cols - 1)
            cell = getcell(t.grid, r, c)
            cell.width == WIDTH_CONTINUATION && continue
            ch = cell.char
            if ch == 0
                print(io, Char(0x20))
            elseif ch <= 0x10FFFF
                print(io, Char(ch))
            else
                print(io, Char(0x20))
            end
        end
        out[r + 1] = rstrip(String(take!(io)))
    end
    return out
end

shadowText(t::ShadowTerm) = join(shadowLines(t), Char(0x0A))

shadowCursor(t::ShadowTerm) = (row = t.cur_row, col = t.cur_col,
                               visible = t.cursor_visible)

end # module ShadowTerminal
