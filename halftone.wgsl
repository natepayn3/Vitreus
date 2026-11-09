// The UwU theme's pop-art print, laid over a drawer's candy body (after the Paper's sheet, same box: the drawer grown by a margin on every side). It does two things:
//   - the HALFTONE: a field of dots on a slanted grid, tiny at the drawer's top left and swelling toward its bottom right, in the accent pink;
//   - the TAPE: a diagonal strip across the top right corner, in hot pink with a fine light dotting and a thin indigo line down each side.
// Both stay inside the body (the rounded rectangle) and never move, so the scene idles at nothing.
//
// s.a.x how strong it is (0 to 1) · s.a.y a seed (unused, kept so the values read like Paper's) · s.a.z the margin round the drawer · s.a.w the corner radius
// s.color the pink · s.color2 the indigo of the tape's lines

fn shade(s: Shader) -> vec4<f32> {
    let m = s.a.z;
    let half = (s.size - vec2<f32>(2.0 * m, 2.0 * m)) * 0.5;
    let q = abs(s.pos - s.size * 0.5) - half + vec2<f32>(s.a.w, s.a.w);
    let d = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - s.a.w;
    let inside = 1.0 - smoothstep(-1.6, -0.4, d);

    let w = s.size.x - 2.0 * m;
    let h = s.size.y - 2.0 * m;
    let p = s.pos - vec2<f32>(m, m);

    // The halftone: dots on a grid turned 45 degrees, bigger toward the bottom right.
    let cell = 7.0;
    let g = vec2<f32>((p.x + p.y) * 0.7071, (p.x - p.y) * 0.7071) / cell;
    let c = fract(g) - vec2<f32>(0.5, 0.5);
    let dist = length(c) * cell;
    let t = clamp((p.x / max(w, 1.0) + p.y / max(h, 1.0)) * 0.5, 0.0, 1.0);
    let rad = cell * 0.5 * smoothstep(0.38, 1.0, t) * 0.92;
    let dots = (1.0 - smoothstep(rad - 0.5, rad + 0.5, dist)) * step(0.01, rad);
    let da = dots * 0.30 * s.a.x * inside;

    // The tape across the top right corner: e grows away from the corner along the diagonal.
    let e = (w - p.x) + p.y;
    let lo = 30.0;
    let hi = 54.0;
    let band = smoothstep(lo - 0.6, lo + 0.6, e) * (1.0 - smoothstep(hi - 0.6, hi + 0.6, e));
    let lines = band * (1.0 - smoothstep(1.2, 2.6, min(e - lo, hi - e)));
    let fine = vec2<f32>((p.x + p.y) * 0.7071, (p.x - p.y) * 0.7071) / 3.6;
    let fd = length(fract(fine) - vec2<f32>(0.5, 0.5)) * 3.6;
    let speck = 1.0 - smoothstep(0.7, 1.3, fd);
    let tape_rgb = mix(s.color.rgb, vec3<f32>(1.0, 0.86, 0.94), speck * 0.55);
    let tape_rgb2 = mix(tape_rgb, s.color2.rgb, lines);
    let ta = band * 0.92 * s.a.x * inside;

    // The tape over the dots.
    let alpha = ta + da * (1.0 - ta);
    let rgb = (tape_rgb2 * ta + s.color.rgb * da * (1.0 - ta)) / max(alpha, 0.0001);
    return vec4<f32>(rgb, alpha);
}
