-- View's controls for videos: what view/view.plm draws for pictures, drawn by mpv (ASS on its OSD) in the shell's colours and look.
--
-- bin/vitreus-view starts mpv with view/player as its config folder and passes the palette (../palette.plm, the theme's colours) and the look
-- (Settings > Theme, as View asks it of Vitreus) as script-opts: 0 Glass, 1 Retro (square corners, a dark outline, a hard shadow), 2 UwU (candy
-- plastic, a thick grape outline, a hard pink shadow), 3 Cyber (near-black glass, a neon hairline, corner brackets), 4 Doodle (paper, an ink
-- outline, a solid ink shadow).
--
-- What it draws: the name's chip at the top left (which of how many, the size, how long), and the pill at the bottom: the one before, play/pause,
-- the one after, the time and the bar to seek on, the sound and its slider, subtitles, the speed, looping, the details and full screen. They show
-- while the pointer moves, while it is over them and while the video is paused, and fade out after a moment of stillness.
-- A click on the video plays or pauses it, a double click fills the screen; the wheel seeks (over the sound, it is the volume).

local mp = require "mp"
local opts = {
    look = 0,
    ink = "dfefdf", faint = "dfe4ea", mint = "e9e4d1", minthi = "faf9f5", onmint = "10161a",
    tint = "2f4056", panel = "3c526d", deep = "1a232f", alert = "d1be94",
    palette = "",          -- the shell's palette.plm: watched, so a new theme (or a new wallpaper's colours) reaches a video that is already playing
}
require("mp.options").read_options(opts, "vitreus-player")
local look = math.max(0, math.min(4, math.floor(tonumber(opts.look) or 0)))

-- ── colours ──
local function rgb(hex)
    hex = tostring(hex):gsub("^#", "")
    return tonumber(hex:sub(1, 2), 16) or 0, tonumber(hex:sub(3, 4), 16) or 0, tonumber(hex:sub(5, 6), 16) or 0
end
local function mix(a, b, t)
    local r1, g1, b1 = rgb(a)
    local r2, g2, b2 = rgb(b)
    return string.format("%02x%02x%02x", math.floor(r1 + (r2 - r1) * t + 0.5), math.floor(g1 + (g2 - g1) * t + 0.5), math.floor(b1 + (b2 - b1) * t + 0.5))
end
local function ass(hex)                                  -- ASS writes colours blue, green, red
    local r, g, b = rgb(hex)
    return string.format("&H%02X%02X%02X&", b, g, r)
end
local C = {
    ink = opts.ink, faint = opts.faint, mint = opts.mint, minthi = opts.minthi, onmint = opts.onmint,
    tint = opts.tint, panel = opts.panel, deep = opts.deep, alert = opts.alert,
    candy = "ffcfe8", pink_shadow = mix(opts.deep, "ff6ec7", 0.75), black = "000000",
}
-- the colours that come from the theme, and those worked out from them
local THEMED = { "ink", "faint", "mint", "minthi", "onmint", "tint", "panel", "deep", "alert" }
local function derive()
    C.pink_shadow = mix(C.deep, "ff6ec7", 0.75)
    mp.set_property("background-color", "#" .. mix(C.tint, C.black, 0.75))     -- the bars beside a video: the theme's tint, nearly black (its `deep` is a colour on some themes: Cyber's is magenta)
end
derive()

-- ── the state ──
local st = {
    w = 0, h = 0, s = 1,                 -- the OSD's size and the monitor's scale
    mx = -1, my = -1, inside = false,    -- the pointer
    moved = 0,                           -- when it last moved
    shown = 0,                           -- how shown the controls are (0 to 1), and where that is going
    want = 1,
    hits = {},                           -- what is under the pointer: { x, y, w, h, id }
    hover = nil,
    drag = nil,                          -- "seek" or "vol" while the button is held on one
    toast = nil, toast_until = 0,
    info = false,
    err = nil,
    click_timer = nil,
}
local overlay = mp.create_osd_overlay("ass-events")
local SPEEDS = { 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3 }

local function now() return mp.get_time() end
local function prop(name, default)
    local v = mp.get_property_native(name)
    if v == nil then return default end
    return v
end

-- ── drawing helpers: everything is drawn with absolute coordinates from \pos(0,0) ──
local function alpha(o)                                  -- an opacity (0 to 1), times how shown the controls are, as ASS's alpha (0 is opaque)
    local a = 255 - math.floor(255 * math.max(0, math.min(1, o)) + 0.5)
    return string.format("&H%02X&", a)
end
local function n(v) return string.format("%.1f", v) end
local function rr(x, y, w, h, r)
    r = math.max(0, math.min(r, w / 2, h / 2))
    local k = r * 0.4477
    return table.concat({
        "m", n(x + r), n(y), "l", n(x + w - r), n(y),
        "b", n(x + w - k), n(y), n(x + w), n(y + k), n(x + w), n(y + r),
        "l", n(x + w), n(y + h - r),
        "b", n(x + w), n(y + h - k), n(x + w - k), n(y + h), n(x + w - r), n(y + h),
        "l", n(x + r), n(y + h),
        "b", n(x + k), n(y + h), n(x), n(y + h - k), n(x), n(y + h - r),
        "l", n(x), n(y + r),
        "b", n(x), n(y + k), n(x + k), n(y), n(x + r), n(y),
    }, " ")
end
-- a filled shape: fill colour and opacity, outline width, colour and opacity, blur
local function shape(path, fill, fo, bw, bc, bo, blur)
    return string.format("{\\an7\\pos(0,0)\\shad0\\bord%s\\blur%s\\1c%s\\1a%s\\3c%s\\3a%s\\p1}%s{\\p0}",
        n(bw or 0), n(blur or 0), ass(fill), alpha(fo * st.shown), ass(bc or fill), alpha((bo or 0) * st.shown), path)
end
-- a line: a path there and back again, with no fill and an outline half as wide as the line
local function stroke(pts, width, colour, o)
    local f = { "m", n(pts[1][1]), n(pts[1][2]) }
    for i = 2, #pts do f[#f + 1] = "l"; f[#f + 1] = n(pts[i][1]); f[#f + 1] = n(pts[i][2]) end
    for i = #pts - 1, 1, -1 do f[#f + 1] = "l"; f[#f + 1] = n(pts[i][1]); f[#f + 1] = n(pts[i][2]) end
    return string.format("{\\an7\\pos(0,0)\\shad0\\bord%s\\blur0.6\\1a&HFF&\\3c%s\\3a%s\\p1}%s{\\p0}",
        n(width / 2), ass(colour), alpha(o * st.shown), table.concat(f, " "))
end
local function arc(cx, cy, r, a0, a1, steps)
    local pts = {}
    for i = 0, steps do
        local a = math.rad(a0 + (a1 - a0) * i / steps)
        pts[#pts + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
    end
    return pts
end
local function esc(t) return (tostring(t):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"):gsub("\n", " ")) end
local function text(x, y, an, size, colour, o, words, bold)
    return string.format("{\\an%d\\pos(%s,%s)\\fn%s\\fs%s\\b%d\\bord0\\shad0\\blur0\\1c%s\\1a%s}%s",
        an, n(x), n(y), "Space Grotesk", n(size), bold and 1 or 0, ass(colour), alpha(o * st.shown), esc(words))
end

-- ── a card in the look: View's Mat (view.plm), as near as ASS gets ──
local function card(out, x, y, w, h, r, o)
    o = o or 1
    if look == 0 then
        out[#out + 1] = shape(rr(x, y + 7 * st.s, w, h, r), C.black, 0.32 * o, 0, nil, 0, 14 * st.s)
        out[#out + 1] = shape(rr(x, y, w, h, r), C.tint, 0.86 * o, 1 * st.s, C.ink, 0.16 * o)
    elseif look == 1 then
        r = math.min(r, 7 * st.s)
        out[#out + 1] = shape(rr(x + 4 * st.s, y + 5 * st.s, w, h, r), C.deep, 0.55 * o)
        out[#out + 1] = shape(rr(x, y, w, h, r), C.tint, o, 1.7 * st.s, C.deep, o)
    elseif look == 2 then
        out[#out + 1] = shape(rr(x + 4 * st.s, y + 5 * st.s, w, h, r), C.pink_shadow, 0.9 * o)
        out[#out + 1] = shape(rr(x, y, w, h, r), C.candy, o, 3 * st.s, C.deep, o)
    elseif look == 3 then
        r = 5 * st.s
        out[#out + 1] = shape(rr(x, y, w, h, r), mix(C.tint, C.black, 0.8), 0.92 * o, 1.2 * st.s, C.mint, 0.9 * o)
        local b = 12 * st.s
        for c = 0, 3 do
            local bx = (c % 2 == 0) and x - 5 * st.s or x + w + 5 * st.s
            local by = (c < 2) and y - 5 * st.s or y + h + 5 * st.s
            local sx = (c % 2 == 0) and 1 or -1
            local sy = (c < 2) and 1 or -1
            out[#out + 1] = stroke({ { bx, by + sy * b }, { bx, by }, { bx + sx * b, by } }, 2 * st.s, C.deep, o)
        end
    else
        r = 4 * st.s
        out[#out + 1] = shape(rr(x + 4 * st.s, y + 4 * st.s, w, h, r), C.ink, o)
        out[#out + 1] = shape(rr(x, y, w, h, r), C.tint, o, 2.4 * st.s, C.ink, o)
    end
end
local function corner(r) return ({ [0] = r, [1] = math.min(r, 7 * st.s), [2] = r, [3] = 5 * st.s, [4] = 4 * st.s })[look] end

-- ── the shell's pencil slider (PSlider in vitreus.plm), as near as ASS gets ──
-- The track pinched in two round the knob, so the level and what is left read as two shapes, each with round outer ends and tighter corners at the cut,
-- each outlined twice in pencil (the second pass fainter and a hair off), still and a little crooked at rest and redrawn five times a second under the
-- pointer; the level coloured in with up-and-down pencil columns (pencilhatch.wgsl, point for point), grey when the sound is off; the knob a pencil ring
-- squeezed into a rounded upright bar. Doodle fills the pieces (the level, and a cream track) and draws them in one thick ink line.
local DD_CREAM = "fffdf6"
local function wob(fr, speed, phase) return math.sin(math.rad((fr * speed + phase) % 360)) end
-- the outline of a rounded box from xa to xb round y, h tall, corner rl on its left and rr on its right, as points, each moved by the pencil (jt, fr, seed)
local function seg_points(xa, xb, y, h, rl, rr_, jt, fr, sd)
    local t, b = y - h / 2, y + h / 2
    local pts = {}
    local function corner(cx, cy, r, a0)
        for i = 0, 4 do
            local a = math.rad(a0 + 90 * i / 4)
            pts[#pts + 1] = { cx + r * math.cos(a), cy + r * math.sin(a) }
        end
    end
    corner(xb - rr_, t + rr_, rr_, -90)
    corner(xb - rr_, b - rr_, rr_, 0)
    corner(xa + rl, b - rl, rl, 90)
    corner(xa + rl, t + rl, rl, 180)
    for i, q in ipairs(pts) do
        q[1] = q[1] + jt * wob(fr, 47 + (i * 7) % 31, sd + i * 61)
        q[2] = q[2] + jt * wob(fr, 52 + (i * 11) % 29, sd + i * 61 + 31)
    end
    pts[#pts + 1] = { pts[1][1], pts[1][2] }
    return pts
end
local function pencil_seg(out, xa, xb, y, h, rl, rr_, hot, sd, o, fill)
    local s = st.s
    if xb - xa < 1 then return end
    rl = math.max(0, math.min(rl, (xb - xa) / 2)); rr_ = math.max(0, math.min(rr_, (xb - xa) / 2))
    if look == 4 then
        if fill then out[#out + 1] = shape(rr(xa, y - h / 2, xb - xa, h, math.min(rl, rr_)), fill, 1) end
        out[#out + 1] = stroke(seg_points(xa, xb, y, h, rl, rr_, 0, 0, sd), 3.2 * s, C.ink, math.min(o, 1))
        return
    end
    local fr = hot and math.floor(now() * 5) or 0
    local jt = (0.18 + (hot and 0.25 or 0)) * s
    out[#out + 1] = stroke(seg_points(xa, xb, y, h, rl, rr_, jt, fr, sd), 1.5 * s, C.ink, math.min(0.6 * o, 1))
    local faint = seg_points(xa, xb, y, h, rl, rr_, jt, fr, sd + 2440)
    for _, q in ipairs(faint) do q[1] = q[1] + 0.35 * s; q[2] = q[2] + 0.28 * s end
    out[#out + 1] = stroke(faint, 1.05 * s, C.ink, 0.2 * o)
end
-- pencilhatch.wgsl's columns: down, up, up, down, each leaning a little, folded onto the level's end
local function hatch(out, xs, xe, y, h, sp, hot, colour, o)
    local s = st.s
    if xe - xs < 1 then return end
    local fr = hot and math.floor(now() * 5) or 0
    local jt = (0.18 + (hot and 0.25 or 0)) * s
    for pass = 0, 1 do
        local pts = {}
        local cols = math.floor((xe - xs) / sp) + 1
        for j = 0, cols * 2 - 1 do
            local col, half, q = math.floor(j / 2), j % 2, j % 4
            local sx = (q == 0 or q == 3) and 1 or -1
            local ax = (pass == 1 and 50 or 0) + 67 * col + 41 * half
            local ay = (pass == 1 and 90 or 0) + 29 * col + 73 * half
            local x = math.min(xs + col * sp, xe) + h * 0.1 * sx + h * 0.02 * math.sin(math.rad(ax % 360)) + jt * wob(fr, 43 + (7 * j) % 31, 97 * j)
            local yy = y - h * 0.38 * sx + h * 0.05 * math.sin(math.rad(ay % 360)) + jt * wob(fr, 48 + (7 * j) % 31, 97 * j + 60)
            if pass == 1 then x = x + 0.3 * s; yy = yy + 0.25 * s end
            pts[#pts + 1] = { x, yy }
        end
        if #pts >= 2 then
            out[#out + 1] = stroke(pts, (pass == 0 and 1.1 or 0.8) * s, colour, (pass == 0 and 0.5 or 0.22) * o)
        end
    end
end
-- the whole slider: x0 its left end, y its middle, w its length, lv the level (0 to 1), hot under the pointer, mute grey
local function pslider(out, x0, y, w, lv, hot, mute, sd)
    local s = st.s
    local h = 11 * s
    local kmin, kmax = x0 + h * 0.6, x0 + w - h * 0.6
    local kx = math.max(kmin, math.min(kmax, x0 + w * lv))
    local kw = h * 0.78
    local kh = h * 2.0
    local kl, kq = kx - kw / 2, kx + kw / 2
    local g = 3 * s
    local lb, ra = kl - g, kq + g
    local ri = h * 0.26
    local lcol = mute and C.faint or C.mint
    if lb - x0 > h * 0.6 then
        pencil_seg(out, x0, lb, y, h, h / 2, ri, hot, sd + 15900, 1, lcol)
        local xs = x0 + h * 0.5
        local xe = math.max(math.min(x0 + w * lv - h * 0.1, lb - h * 0.2), xs)
        if look ~= 4 then hatch(out, xs, xe, y, h, math.max(2.5 * s, (w - h) / 86), hot, lcol, mute and 0.45 or 1) end
    end
    if x0 + w - ra > h * 0.6 then pencil_seg(out, ra, x0 + w, y, h, ri, h / 2, hot, sd + 24100, 1, DD_CREAM) end
    -- the knob
    out[#out + 1] = shape(rr(kl, y - kh / 2, kw, kh, kw * 0.45), look == 4 and DD_CREAM or C.ink, look == 4 and 1 or 0.14)
    pencil_seg(out, kl, kq, y, kh, kw * 0.45, kw * 0.45, hot, sd + 31700, 1.5)
end

-- ── icons: View's own (view.plm, `Tb`), line for line: drawn about their middle (x, y), in pixels times the scale, thin round-ended lines in ink ──
local function icon(out, name, x, y, colour, o)
    local s = st.s
    local function P(px, py) return { x + px * s, y + py * s } end
    local function line(w, ...)
        local pts = {}
        for _, q in ipairs({ ... }) do pts[#pts + 1] = P(q[1], q[2]) end
        out[#out + 1] = stroke(pts, w * s, colour, o)
    end
    local function ring(cx, cy, r, w, a0, a1)
        out[#out + 1] = stroke(arc(x + cx * s, y + cy * s, r * s, a0 or 0, a1 or 360, 32), w * s, colour, o)
    end
    local function solid(...)
        local f = {}
        for i, q in ipairs({ ... }) do
            local pt = P(q[1], q[2])
            f[#f + 1] = (i == 1) and "m" or "l"; f[#f + 1] = n(pt[1]); f[#f + 1] = n(pt[2])
        end
        out[#out + 1] = shape(table.concat(f, " "), colour, o, 0.4 * s, colour, o)
    end
    local function bar(cx, cy, w, h, r)
        out[#out + 1] = shape(rr(x + (cx - w / 2) * s, y + (cy - h / 2) * s, w * s, h * s, r * s), colour, o)
    end
    if name == "prev" then line(2.6, { 4, -8 }, { -4, 0 }, { 4, 8 })
    elseif name == "next" then line(2.6, { -4, -8 }, { 4, 0 }, { -4, 8 })
    elseif name == "play" then solid({ -4.5, -7.5 }, { 7.5, 0 }, { -4.5, 7.5 })
    elseif name == "pause" then bar(-3.5, 0, 3.6, 14, 1); bar(3.5, 0, 3.6, 14, 1)
    elseif name == "replay" then                                   -- View's «turn left»: three quarters of a circle, its head at the top
        ring(0, 0, 7, 2.2, -90, 180)
        line(2.2, { 3.5, -10.5 }, { 0, -7 }, { 3.5, -3.5 })
    elseif name == "vol" or name == "vol0" or name == "mute" then
        line(2, { -8, -3 }, { -4.5, -3 }, { 0.5, -7.5 }, { 0.5, 7.5 }, { -4.5, 3 }, { -8, 3 }, { -8, -3 })
        if name == "mute" then
            line(2, { 4, -3.5 }, { 9.5, 3.5 })
            line(2, { 9.5, -3.5 }, { 4, 3.5 })
        else
            ring(1, 0, 4.5, 2, -42, 42)
            if name == "vol" then ring(1, 0, 8.5, 2, -42, 42) end
        end
    elseif name == "full" or name == "unfull" then                 -- View's «fit»: four corners (pointing out to fill, in to leave)
        for c = 0, 3 do
            local sx = (c % 2 == 0) and -1 or 1
            local sy = (c < 2) and -1 or 1
            if name == "full" then
                line(2.2, { sx * 8, sy * 8 - sy * 5 }, { sx * 8, sy * 8 }, { sx * 8 - sx * 5, sy * 8 })
            else
                line(2.2, { sx * 3, sy * 8 }, { sx * 3, sy * 3 }, { sx * 8, sy * 3 })
            end
        end
    elseif name == "subs" then                                     -- a screen (as View's «wallpaper») with two lines of words on it
        out[#out + 1] = shape(rr(x - 9.5 * s, y - 6.5 * s, 19 * s, 13 * s, 2 * s), colour, 0, 1 * s, colour, o)
        line(2, { -5.5, 1.5 }, { -1.5, 1.5 })
        line(2, { 1, 1.5 }, { 5.5, 1.5 })
        line(2, { -5.5, -2 }, { 3, -2 })
    elseif name == "loop" then                                     -- two arrows going round
        line(2.1, { -7.5, 1.5 }, { -7.5, -4 }, { 6.5, -4 })
        line(2.1, { 3.5, -7 }, { 6.5, -4 }, { 3.5, -1 })
        line(2.1, { 7.5, -1.5 }, { 7.5, 4 }, { -6.5, 4 })
        line(2.1, { -3.5, 1 }, { -6.5, 4 }, { -3.5, 7 })
    elseif name == "info" then                                     -- an i in a ring
        ring(0, 0, 8.5, 2)
        bar(0, 2, 2.4, 7, 1)
        out[#out + 1] = shape(rr(x - 1.5 * s, y - 5.5 * s, 3 * s, 3 * s, 1.5 * s), colour, o)
    end
end

-- ── what is said about the video ──
local function clock(t)
    t = math.max(0, math.floor(t or 0))
    local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end
local function say(words, secs)
    st.toast = words
    st.toast_until = now() + (secs or 1.6)
    st.moved = now()
end
local function tracks(kind)
    local list = {}
    for _, t in ipairs(prop("track-list", {})) do if t.type == kind then list[#list + 1] = t end end
    return list
end
local function track_name(t)
    if not t then return "off" end
    local bits = {}
    if t.title then bits[#bits + 1] = t.title end
    if t.lang then bits[#bits + 1] = t.lang end
    if #bits == 0 then bits[1] = "track " .. t.id end
    return table.concat(bits, " · ")
end
local function selected(kind)
    for _, t in ipairs(tracks(kind)) do if t.selected then return t end end
end

-- ── the picture of it all ──
local render
local function hit(x, y, w, h, id) st.hits[#st.hits + 1] = { x = x, y = y, w = w, h = h, id = id } end

local function draw_controls(out)
    local s, w, h = st.s, st.w, st.h
    local pos, dur = prop("time-pos", 0), prop("duration", 0)
    local paused, ended = prop("pause", false), prop("eof-reached", false)
    local vol, muted = prop("volume", 100), prop("mute", false)
    local full = prop("fullscreen", false)
    local count, at = prop("playlist-count", 1), prop("playlist-pos", 0) + 1

    -- the name's chip
    local name = prop("media-title", prop("filename", ""))
    local vw, vh = prop("width", 0), prop("height", 0)
    local sub = {}
    if count > 1 then sub[#sub + 1] = string.format("%d of %d", at, count) end
    if vw > 0 then sub[#sub + 1] = string.format("%d × %d", vw, vh) end
    if dur > 0 then sub[#sub + 1] = clock(dur) end
    local subline = table.concat(sub, "  ·  ")
    if name ~= "" and not st.err then
        local cw = math.min(w - 32 * s, math.max(#name * 8.4, #subline * 6.6) * s + 32 * s)
        card(out, 16 * s, 16 * s, cw, 50 * s, corner(16 * s))
        out[#out + 1] = text(32 * s, 23 * s, 7, 16 * s, C.ink, 1, name, true)
        out[#out + 1] = text(32 * s, 43 * s, 7, 12 * s, C.faint, 0.75, subline)
    end

    -- the pill: View's (52 high, round ends), with its trims: UwU's ears at the two ends, Retro's accent tab, Doodle's tape
    local ph = 52 * s
    local pw = math.min(w - 32 * s, 900 * s)
    local px, py = (w - pw) / 2, h - 18 * s - ph
    card(out, px, py, pw, ph, corner(26 * s))
    if look == 2 then
        for side = 0, 1 do
            local ex = (side == 0) and px + 46 * s or px + pw - 46 * s
            local sg = (side == 0) and -1 or 1
            local function ear(k, col, fo, bw)
                local pts = { { ex - 21 * k * s, py + 8 * k * s }, { ex + sg * 12 * k * s, py - 27 * k * s }, { ex + 21 * k * s, py + 8 * k * s } }
                local f = { "m", n(pts[1][1]), n(pts[1][2]), "l", n(pts[2][1]), n(pts[2][2]), "l", n(pts[3][1]), n(pts[3][2]) }
                out[#out + 1] = shape(table.concat(f, " "), col, fo, bw, C.deep, bw > 0 and 1 or 0)
            end
            ear(1, side == 0 and C.candy or "d2fff0", 1, 1.5 * s)
            ear(0.62, "ff8fc8", 1, 0)
        end
    elseif look == 1 then
        out[#out + 1] = shape(rr(px + 22 * s, py - 4 * s, 30 * s, 6 * s, 2 * s), C.mint, 1, 0.75 * s, C.deep, 1)
    elseif look == 4 then
        local cx0, cy0, a = px + 34 * s, py + 1 * s, math.rad(-6)
        local function R(dx, dy) return n(cx0 + dx * math.cos(a) - dy * math.sin(a)), n(cy0 + dx * math.sin(a) + dy * math.cos(a)) end
        local x1, y1 = R(-30 * s, -8 * s); local x2, y2 = R(30 * s, -8 * s); local x3, y3 = R(30 * s, 8 * s); local x4, y4 = R(-30 * s, 8 * s)
        out[#out + 1] = shape(table.concat({ "m", x1, y1, "l", x2, y2, "l", x3, y3, "l", x4, y4 }, " "), "f7a8c4", 0.78)
    end
    hit(px, py, pw, ph, "pill")
    local cy = py + ph / 2
    local B = 38 * s
    local function sep(x)
        out[#out + 1] = shape(rr(x - 0.5 * s, cy - 12 * s, 1 * s, 24 * s, 0), C.ink, 0.22)
    end
    local function hover_box(x, wd, id)
        local hv = st.hover == id
        if not hv then return end
        local r = ({ [0] = 13, 4, 13, 3, 2 })[look] * s
        out[#out + 1] = shape(rr(x, cy - B / 2, wd, B, r), C.mint, 0.24)
        if look == 1 or look == 2 or look == 4 then out[#out + 1] = shape(rr(x, cy - B / 2, wd, B, r), C.ink, 0, 0.8 * s, C.ink, 0.7) end
    end
    local function button(id, ic, x, tip, en, sel)
        if en ~= false then
            if sel then out[#out + 1] = shape(rr(x, cy - B / 2, B, B, ({ [0] = 13, 4, 13, 3, 2 })[look] * s), C.mint, 0.45) end
            hover_box(x, B, id)
        end
        icon(out, ic, x + B / 2, cy, C.ink, (en == false) and 0.35 or 1)
        if en ~= false then hit(x, cy - B / 2, B, B, id) end
        if st.hover == id and tip then st.tip = { x = x + B / 2, y = py - 10 * s, words = tip } end
    end
    local G = 44 * s                                      -- one button to the next, as View's
    local x = px + 30 * s - B / 2
    button("prev", "prev", x, "The one before (Page Up)", count > 1); x = x + G
    button("play", ended and "replay" or (paused and "play" or "pause"), x, ended and "Again" or (paused and "Play (Space)" or "Pause (Space)")); x = x + G
    button("next", "next", x, "The one after (Page Down)", count > 1); x = x + B + 3 * s
    sep(x); x = x + 6 * s
    local left = x

    -- from the right
    local r = px + pw - 30 * s - B / 2
    button("full", full and "unfull" or "full", r, full and "Leave full screen (F)" or "Full screen (F)"); r = r - G
    button("info", "info", r, "Details (I)", true, st.info); r = r - G
    local looping = prop("loop-file", "no")
    button("loop", "loop", r, "Loop (L)", true, looping ~= "no" and looping ~= false); r = r - G
    -- the speed, as words (as View's zoom: 13, bold)
    local sp = prop("speed", 1)
    hover_box(r, B, "speed")
    out[#out + 1] = text(r + B / 2, cy, 5, 13 * s, C.ink, 1, (string.format("%g", sp)) .. "×", true)
    hit(r, cy - B / 2, B, B, "speed")
    if st.hover == "speed" then st.tip = { x = r + B / 2, y = py - 10 * s, words = "Speed ([ and ])" } end
    r = r - G
    local has_subs = #tracks("sub") > 0
    button("subs", "subs", r, has_subs and "Subtitles (C)" or "No subtitles", has_subs, selected("sub") ~= nil)
    r = r - 6 * s
    sep(r)
    r = r - 12 * s
    -- the sound and its slider
    local vsw = 84 * s
    r = r - vsw
    local vk = math.max(0, math.min(1, vol / 100))
    local vhot = st.hover == "vol" or st.drag == "vol"
    pslider(out, r, cy, vsw, vk, vhot, muted, 0)
    if vhot then st.tip = { x = r + vsw * vk, y = py - 10 * s, words = string.format("%d %%", math.floor(vol + 0.5)) } end
    hit(r - 4 * s, cy - B / 2, vsw + 8 * s, B, "vol")
    st.vol_x, st.vol_w = r, vsw
    r = r - B - 2 * s
    button("mute", muted and "mute" or (vol < 50 and "vol0" or "vol"), r, muted and "Sound on (M)" or "Mute (M)")
    r = r - 6 * s
    sep(r)
    r = r - 12 * s

    -- the time and the bar to seek on
    local tl = clock(pos)
    local tr = dur > 0 and clock(dur) or "--:--"
    local tw = (dur >= 3600 and 62 or 44) * s
    out[#out + 1] = text(left + tw, cy, 6, 13 * s, C.ink, 1, tl, true)
    out[#out + 1] = text(r, cy, 6, 13 * s, C.ink, 0.6, tr, true)
    local bx, bw = left + tw + 12 * s, (r - tw) - (left + tw + 12 * s) - 12 * s
    if bw > 40 * s then
        local k = (dur > 0) and math.max(0, math.min(1, pos / dur)) or 0
        local hv = st.hover == "seek" or st.drag == "seek"
        pslider(out, bx, cy, bw, k, hv, false, 5000)
        if hv and dur > 0 and st.mx >= bx and st.mx <= bx + bw then
            st.tip = { x = st.mx, y = py - 10 * s, words = clock((st.mx - bx) / bw * dur) }
        end
        hit(bx - 6 * s, cy - B / 2, bw + 12 * s, B, "seek")
        st.seek_x, st.seek_w = bx, bw
    else
        st.seek_x, st.seek_w = nil, nil
    end
end

local function draw_tip(out)
    local t = st.tip
    if not t then return end
    local s = st.s
    local tw = #t.words * 7.4 * s + 22 * s
    local x = math.max(8 * s, math.min(st.w - tw - 8 * s, t.x - tw / 2))
    card(out, x, t.y - 30 * s, tw, 28 * s, corner(14 * s))
    out[#out + 1] = text(x + tw / 2, t.y - 16 * s, 5, 12.5 * s, C.ink, 1, t.words)
end

local function draw_toast(out)
    if not st.toast or now() > st.toast_until then return end
    local s = st.s
    local tw = #st.toast * 8 * s + 36 * s
    card(out, (st.w - tw) / 2, 22 * s, tw, 40 * s, corner(20 * s))
    out[#out + 1] = text(st.w / 2, 42 * s, 5, 14 * s, C.ink, 1, st.toast, true)
end

local function draw_info(out)
    if not st.info then return end
    local s = st.s
    local rows = {}
    local function row(k, v) if v and v ~= "" then rows[#rows + 1] = { k, tostring(v) } end end
    row("Name", prop("filename", ""))
    local size = prop("file-size", 0)
    if size > 0 then
        local u, v = { "KB", "MB", "GB" }, size / 1024
        local i = 1
        while v >= 1024 and i < #u do v = v / 1024; i = i + 1 end
        row("Size", string.format(v < 10 and "%.1f %s" or "%.0f %s", v, u[i]))
    end
    local vw, vh = prop("width", 0), prop("height", 0)
    if vw > 0 then row("Picture", string.format("%d × %d", vw, vh)) end
    local fps = prop("container-fps", 0)
    if fps > 0 then row("Frames", string.format("%.3g a second", fps)) end
    row("Video", prop("video-codec", ""))
    row("Sound", prop("audio-codec-name", ""))
    local dur = prop("duration", 0)
    if dur > 0 then row("Length", clock(dur)) end
    row("Decoded by", prop("hwdec-current", "no") ~= "no" and "the graphics card" or "the processor")
    local w = 420 * s
    local h = (24 + #rows * 26) * s
    local x, y = st.w - w - 16 * s, 16 * s
    card(out, x, y, w, h, corner(18 * s))
    for i, r in ipairs(rows) do
        local ry = y + 12 * s + (i - 1) * 26 * s + 13 * s
        out[#out + 1] = text(x + 18 * s, ry, 4, 12.5 * s, C.faint, 0.75, r[1])
        local v = r[2]
        if #v > 44 then v = v:sub(1, 42) .. "…" end
        out[#out + 1] = text(x + 120 * s, ry, 4, 13 * s, C.ink, 1, v)
    end
end

local function draw_error(out)
    if not st.err then return end
    local s = st.s
    local w, h = 460 * s, 76 * s
    local x, y = (st.w - w) / 2, (st.h - h) / 2
    card(out, x, y, w, h, corner(22 * s))
    out[#out + 1] = text(st.w / 2, y + 28 * s, 5, 17 * s, C.ink, 1, "This video could not be played", true)
    out[#out + 1] = text(st.w / 2, y + 52 * s, 5, 12.5 * s, C.faint, 0.75, st.err)
end

render = function()
    if st.w <= 0 then return end
    local keep = st.shown
    st.hits, st.tip = {}, nil
    local out = {}
    if st.shown > 0.01 then
        draw_controls(out)
        draw_info(out)
    end
    st.shown = 1                                          -- these stay up whatever the controls do
    draw_toast(out)
    draw_error(out)
    st.shown = keep
    draw_tip(out)
    overlay.res_x, overlay.res_y = st.w, st.h
    overlay.data = table.concat(out, "\n")
    overlay:update()
end

-- ── showing and hiding ──
local function over_controls()
    for _, h in ipairs(st.hits) do
        if st.mx >= h.x and st.mx <= h.x + h.w and st.my >= h.y and st.my <= h.y + h.h then return true end
    end
    return false
end
local function wanted()
    if st.drag or st.info or st.err then return 1 end
    if prop("pause", false) or prop("eof-reached", false) or prop("idle-active", false) then return 1 end
    if st.inside and over_controls() then return 1 end
    if now() - st.moved < 1.8 then return 1 end
    return 0
end
local ticker
ticker = mp.add_periodic_timer(1 / 30, function()
    st.want = wanted()
    local d = st.want - st.shown
    if math.abs(d) > 0.01 then
        st.shown = st.shown + d * 0.28
        if math.abs(st.want - st.shown) < 0.02 then st.shown = st.want end
    end
    render()
    -- nothing moving and nothing shown: rest (a property change or the pointer wakes it)
    if st.shown == 0 and st.want == 0 and not (st.toast and now() < st.toast_until) then ticker:kill() end
end)
local function wake()
    if not ticker:is_enabled() then ticker:resume() end
end

-- ── the pointer ──
local function under(x, y)
    for i = #st.hits, 1, -1 do
        local h = st.hits[i]
        if h.id ~= "pill" and x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return h.id end
    end
    for _, h in ipairs(st.hits) do
        if h.id == "pill" and x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then return "pill" end
    end
end
local function seek_to(x, exact)
    if not st.seek_x then return end
    local dur = prop("duration", 0)
    if dur <= 0 then return end
    local k = math.max(0, math.min(1, (x - st.seek_x) / st.seek_w))
    mp.commandv("seek", tostring(k * dur), exact and "absolute+exact" or "absolute+keyframes")
end
local function vol_to(x)
    if not st.vol_x then return end
    local k = math.max(0, math.min(1, (x - st.vol_x) / st.vol_w))
    mp.set_property_number("volume", math.floor(k * 100 + 0.5))
    if prop("mute", false) then mp.set_property_bool("mute", false) end
end
mp.observe_property("mouse-pos", "native", function(_, p)
    if not p then return end
    local moved = (p.x ~= st.mx or p.y ~= st.my)
    st.mx, st.my, st.inside = p.x, p.y, p.hover
    if moved then st.moved = now() end
    st.hover = st.shown > 0.5 and under(p.x, p.y) or nil
    if st.drag == "seek" then seek_to(p.x, false) elseif st.drag == "vol" then vol_to(p.x) end
    wake()
end)

local function cycle_speed(up)
    local sp = prop("speed", 1)
    local pick = sp
    if up then
        for _, v in ipairs(SPEEDS) do if v > sp + 0.001 then pick = v break end end
    else
        for i = #SPEEDS, 1, -1 do if SPEEDS[i] < sp - 0.001 then pick = SPEEDS[i] break end end
    end
    mp.set_property_number("speed", pick)
    say(string.format("Speed %g×", pick))
end
local function cycle_track(kind, what)
    local list = tracks(kind)
    if #list == 0 then say(kind == "sub" and "This video has no subtitles" or "This video has no sound") return end
    mp.command(kind == "sub" and "cycle sub" or "cycle audio")
    mp.add_timeout(0.05, function()
        local t = selected(kind)
        say(what .. ": " .. track_name(t))
        wake()
    end)
end
local function toggle_loop()
    local l = prop("loop-file", "no")
    local on = (l == "no" or l == false)
    mp.set_property("loop-file", on and "inf" or "no")
    say(on and "Looping this one" or "Not looping")
end

local function press(id)
    if id == "play" then
        if prop("eof-reached", false) then mp.commandv("seek", "0", "absolute"); mp.set_property_bool("pause", false)
        else mp.command("cycle pause") end
    elseif id == "prev" then mp.command("playlist-prev")
    elseif id == "next" then mp.command("playlist-next")
    elseif id == "full" then mp.command("cycle fullscreen")
    elseif id == "info" then st.info = not st.info
    elseif id == "loop" then toggle_loop()
    elseif id == "speed" then if prop("speed", 1) >= SPEEDS[#SPEEDS] then mp.set_property_number("speed", 1); say("Speed 1×") else cycle_speed(true) end
    elseif id == "subs" then cycle_track("sub", "Subtitles")
    elseif id == "mute" then mp.command("cycle mute")
    end
    wake()
end

mp.add_forced_key_binding("MBTN_LEFT", "vp-click", function(e)
    local id = under(st.mx, st.my)
    if st.shown < 0.5 then id = nil end
    if e.event == "down" then
        if id == "seek" then st.drag = "seek"; seek_to(st.mx, false)
        elseif id == "vol" then st.drag = "vol"; vol_to(st.mx)
        elseif id and id ~= "pill" then press(id)
        elseif not id then
            -- on the video: play or pause, unless it was the first half of a double click
            if st.click_timer then st.click_timer:kill() end
            st.click_timer = mp.add_timeout(0.26, function() st.click_timer = nil; press("play") end)
        end
    elseif e.event == "up" then
        if st.drag == "seek" then seek_to(st.mx, true) end
        st.drag = nil
    end
    wake()
end, { complex = true })
mp.add_forced_key_binding("MBTN_LEFT_DBL", "vp-dbl", function()
    if st.click_timer then st.click_timer:kill(); st.click_timer = nil end
    if st.shown > 0.5 and under(st.mx, st.my) then return end
    mp.command("cycle fullscreen")
end)

-- ── the keys input.conf hands here ──
mp.add_key_binding(nil, "subs", function() cycle_track("sub", "Subtitles") end)
mp.add_key_binding(nil, "audio", function() cycle_track("audio", "Sound") end)
mp.add_key_binding(nil, "faster", function() cycle_speed(true); wake() end)
mp.add_key_binding(nil, "slower", function() cycle_speed(false); wake() end)
mp.add_key_binding(nil, "loop", function() toggle_loop(); wake() end)
mp.add_key_binding(nil, "info", function() st.info = not st.info; wake() end)
mp.add_key_binding(nil, "escape", function()
    if prop("fullscreen", false) then mp.set_property_bool("fullscreen", false)
    elseif st.info then st.info = false; wake()
    else mp.command("quit") end
end)
local function wheel(dir)
    if st.shown > 0.5 and (under(st.mx, st.my) == "vol" or under(st.mx, st.my) == "mute") then
        mp.commandv("add", "volume", tostring(5 * dir))
        say(string.format("Sound %d %%", math.floor(prop("volume", 100) + 0.5)), 0.8)
    else
        mp.commandv("seek", tostring(5 * dir))
    end
    st.moved = now()
    wake()
end
mp.add_key_binding(nil, "wheel_up", function() wheel(1) end)
mp.add_key_binding(nil, "wheel_down", function() wheel(-1) end)

-- ── what changes it ──
local function size()
    local d = prop("osd-dimensions", {})
    st.w, st.h = d.w or 0, d.h or 0
    st.s = prop("display-hidpi-scale", 1) or 1
    wake()
end
mp.observe_property("osd-dimensions", "native", size)
mp.observe_property("display-hidpi-scale", "native", size)
for _, p in ipairs({ "pause", "eof-reached", "fullscreen", "volume", "mute", "speed", "loop-file", "playlist-pos", "track-list", "duration" }) do
    mp.observe_property(p, "native", function() wake() end)
end
mp.register_event("start-file", function() st.err = nil; st.moved = now(); wake() end)
mp.register_event("end-file", function(e)
    if e.reason == "error" then
        st.err = e.file_error or "mpv could not read it"
        wake()
    end
end)

-- ── the theme, on the fly ──
-- A new theme (Settings > Theme) and a new wallpaper's colours (Iris) rewrite the shell's palette.plm, as they do for View, which reloads with it. Nothing
-- here polls: ../watch-palette.py waits on the file, asleep (inotify), until it changes, and then the colours are read from it again and the look is asked of Vitreus
-- again (`look_v`, as View and bin/vitreus-view ask it: 1 Retro, 2 UwU, 3 Cyber and Proxy, 7 Doodle; the rest Glass), and the watch starts again.
-- The watcher goes with the player. VIEW_LOOK, set to try a look, keeps the one it gave.
local LOOK_OF = { [0] = 0, [1] = 1, [2] = 2, [3] = 3, [7] = 4 }
local function read_palette()
    local f = io.open(opts.palette, "r")
    if not f then return end
    local body = f:read("*a")
    f:close()
    for _, k in ipairs(THEMED) do
        local hex = body:match("let%s+" .. k .. "%s*=%s*#(%x%x%x%x%x%x)")
        if hex then C[k] = hex:lower() end
    end
    derive()
end
local function ask_look()
    if os.getenv("VIEW_LOOK") then return end
    mp.command_native_async({ name = "subprocess", args = { "pleamar", "--say", "vitreus", "get look_v" }, capture_stdout = true, capture_stderr = true, playback_only = false },
        function(ok, r)
            if not ok or not r or r.status ~= 0 then return end
            local v = tonumber((r.stdout or ""):match("%-?%d+"))
            if v then
                local new = LOOK_OF[v] or 0
                if new ~= look then look = new; wake() end
            end
        end)
end
-- ../watch-palette.py: one python process asleep on inotify until the file changes, then it ends (mpv ending kills it, and nothing is left)
local WATCHER = mp.command_native({ "expand-path", "~~/watch-palette.py" })
local watcher = nil
local stopping = false
local function watch()
    if stopping then return end
    watcher = mp.command_native_async({ name = "subprocess", args = { "python3", "-I", WATCHER, opts.palette }, playback_only = false, capture_stdout = true },
        function(ok, r)
            watcher = nil
            if stopping then return end
            if not ok or not r or r.status ~= 0 then return end          -- (no python, or it could not watch: the theme is the one it started with)
            -- a theme writes the file in one go, but give it a moment, and gather what comes with it
            mp.add_timeout(0.3, function() read_palette(); ask_look(); wake(); watch() end)
        end)
end
if opts.palette ~= "" then read_palette(); watch() end
mp.register_event("shutdown", function()
    stopping = true
    if watcher then mp.abort_async_command(watcher) end
end)
