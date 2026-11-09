// The Cyber theme's digital rain: columns of little glyphs fall down a drawer's glass, each with a bright head and a trail that fades behind it. The glyphs are
// not a font: each is a 5 by 7 grid of dots, filled by chance and mirrored left to right (so it reads as a symbol), and a cell picks another one every
// so often. Everything is worked out from the column and the row, so it needs no memory.
//
// s.a.x how strong it is (0 to 1) · s.a.y how fast it falls (1 is the usual) · s.color the trail, s.color2 the head

fn hash(p: vec2<f32>) -> f32 {
    var q = fract(p * vec2<f32>(0.1031, 0.1030));
    q = q + dot(q, q.yx + vec2<f32>(33.33, 33.33));
    return fract((q.x + q.y) * q.x);
}

fn rain(s: Shader) -> vec4<f32> {
    let cw = 17.0;
    let ch = 24.0;
    let col = floor(s.pos.x / cw);
    let row = floor(s.pos.y / ch);
    let rows = ceil(s.size.y / ch);

    // Each column: whether it rains at all, how fast, how long its trail is, where it started.
    let live = hash(vec2<f32>(col, 1.7));
    if (live < 0.35) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    let speed = (3.5 + 6.0 * hash(vec2<f32>(col, 4.1))) * s.a.y;       // rows a second
    let trail = 8.0 + 14.0 * hash(vec2<f32>(col, 9.3));
    let span = rows + trail + 6.0;
    let head = (s.time * speed + span * hash(vec2<f32>(col, 2.9))) % span;
    let behind = head - row;
    if (behind < 0.0 || behind > trail) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }

    // The glyph in this cell, and which one it is now (the head's changes quickly, the trail's slowly).
    let which = floor(s.time * (3.0 + 9.0 * step(behind, 1.0)) + hash(vec2<f32>(col, row)) * 40.0);
    let local = vec2<f32>(fract(s.pos.x / cw), fract(s.pos.y / ch));
    let gx = floor((local.x - 0.12) / 0.76 * 5.0);
    let gy = floor((local.y - 0.1) / 0.8 * 7.0);
    if (gx < 0.0 || gx > 4.0 || gy < 0.0 || gy > 6.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    let fx = min(gx, 4.0 - gx);
    let on = step(0.5, hash(vec2<f32>(fx + col * 7.0 + which * 3.0, gy + row * 11.0)));

    let fade = pow(1.0 - behind / trail, 1.6);
    let tip = 1.0 - smoothstep(0.0, 1.2, behind);
    let rgb = mix(s.color.rgb, s.color2.rgb, tip);
    return vec4<f32>(rgb, on * mix(fade * 0.5, 0.9, tip) * s.a.x);
}

// The HUD's glass: fine scan lines across the whole drawer, a slow bright band that sweeps down it, and a wash of the second neon (magenta) along its
// top edge and of the first (cyan) along its bottom one, as a monitor's phosphor would give. The rain falls on top of it.
fn shade(s: Shader) -> vec4<f32> {
    let r = rain(s);
    let k = s.a.x;
    let lines = 0.5 + 0.5 * cos(s.pos.y * 2.0943951);                  // one line every 3 px
    let sweep_y = fract(s.time * 0.07) * (s.size.y + 120.0) - 60.0;
    let band = exp(-pow((s.pos.y - sweep_y) / 34.0, 2.0));
    let top = pow(1.0 - clamp(s.pos.y / s.size.y, 0.0, 1.0), 3.0);
    let bot = pow(clamp(s.pos.y / s.size.y, 0.0, 1.0), 3.0);
    let wash = vec3<f32>(1.0, 0.17, 0.84) * (top * 0.06) + s.color.rgb * (bot * 0.05);
    let wa = top * 0.06 + bot * 0.05;
    let ha = (lines * 0.06 + band * 0.07);
    // base layer: wash and scan lines, premultiplied
    let base_rgb = wash + s.color2.rgb * ha;
    let base_a = clamp(wa + ha, 0.0, 1.0);
    let ra = r.a;
    let out_a = ra + base_a * (1.0 - ra);
    let out_rgb = (r.rgb * ra + base_rgb * (1.0 - ra)) / max(out_a, 0.0001);
    return vec4<f32>(out_rgb, out_a * min(1.0, k * 3.5));
}
