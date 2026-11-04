// The pencil shading inside a slider (PSlider in vitreus.plm): the level coloured in with a pencil, in tight columns up and down, the second pass
// fainter and a hair off. It is the same line the two 176-point paths drew, worked out here instead: as paths they were 56 KB of expressions,
// written out again for each of the 53 sliders, and a tenth of the time the whole shell took to read when it started.
//
// Point j (0 to 175) of a pass: column j / 2, the top or the bottom of it (down, up, up, down… in fours), leaning h * 0.1 one way at the top and the
// other at the bottom, with two fixed wobbles (h * 0.02 across, h * 0.05 down) and the pencil's own (`jt`, moving with the frame `fr`). The columns
// past the level fold onto its end (`xe`), as `min(xs + c * sp, xe)` did. The constants are the ones the paths were written with (degrees).
//
// values: xs, xe, sp, h  (in the box: xs and xe from its left edge; the line's middle is the box's middle) · jt, fr, stroke, pass (0 the strong one, 1 the faint one)
// colors: the pencil's colour

fn ph_sin(deg: f32) -> f32 {
    return sin(deg * 0.017453292519943295);
}

// The angle of a wobble, kept small: fr is a whole number of frames that only grows, and its product with the speed, as degrees, goes past what an
// f32 holds exactly within hours. A whole turn is 360, so (fr mod 360) * speed + phase gives the same sine.
fn ph_turn(fr: f32, speed: f32, phase: f32) -> f32 {
    let f = fr - 360.0 * floor(fr / 360.0);
    let a = f * speed + phase;
    return a - 360.0 * floor(a / 360.0);
}

fn ph_point(j: u32, s: Shader, mid: f32) -> vec2<f32> {
    let xs = s.a.x;
    let xe = s.a.y;
    let sp = s.a.z;
    let h = s.a.w;
    let jt = s.b.x;
    let fr = s.b.y;
    let faint = s.b.w > 0.5;
    let col = f32(j / 2u);
    let half = f32(j % 2u);
    // down, up, up, down: the sign of the lean, and the top (-0.38) or the bottom (+0.38) of the column
    let q = j % 4u;
    let sx = select(-1.0, 1.0, q == 0u || q == 3u);
    // the fixed wobbles' angles, and the pencil's: a speed and a phase each (the faint pass starts at other ones)
    let ax0 = select(0.0, 50.0, faint);
    let ay0 = select(0.0, 90.0, faint);
    let fx0 = select(6.0, 21.0, faint);
    let px0 = select(18550.0, 18921.0, faint);
    let ax = ax0 + 67.0 * col + 41.0 * half;
    let ay = ay0 + 29.0 * col + 73.0 * half;
    let fx = 43.0 + f32((u32(fx0) + 7u * j) % 31u);
    let px = px0 + 97.0 * f32(j);
    let x = min(xs + col * sp, xe) + h * 0.1 * sx + h * 0.02 * ph_sin(ax - 360.0 * floor(ax / 360.0)) + jt * ph_sin(ph_turn(fr, fx, px - 360.0 * floor(px / 360.0)));
    let y = mid - h * 0.38 * sx + h * 0.05 * ph_sin(ay - 360.0 * floor(ay / 360.0)) + jt * ph_sin(ph_turn(fr, fx + 5.0, px + 60.0 - 360.0 * floor((px + 60.0) / 360.0)));
    return vec2<f32>(x, y);
}

fn ph_segment(p: vec2<f32>, a: vec2<f32>, b: vec2<f32>) -> f32 {
    let ab = b - a;
    let t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - a - ab * t);
}

fn shade(s: Shader) -> vec4<f32> {
    let xs = s.a.x;
    let xe = s.a.y;
    let sp = s.a.z;
    let h = s.a.w;
    let jt = s.b.x;
    let w = s.b.z;
    let mid = s.size.y * 0.5;
    let p = s.pos;
    // How far a point can stray from its column's x: the lean, the fixed wobble, the pencil's, and half the line.
    let reach = h * 0.12 + abs(jt) + w;
    var d = 1e9;
    var prev = ph_point(0u, s, mid);
    var prev_base = min(xs, xe);
    for (var j = 1u; j < 176u; j = j + 1u) {
        let base = min(xs + f32(j / 2u) * sp, xe);
        // Only the strokes near this pixel are measured: the columns are in order along x, so one whose two ends are both far from it is skipped.
        let near = abs(p.x - base) < reach + sp || abs(p.x - prev_base) < reach + sp;
        let here = ph_point(j, s, mid);
        if (near) {
            d = min(d, ph_segment(p, prev, here));
        }
        prev = here;
        prev_base = base;
    }
    // A line `w` wide with round ends, its edge smoothed over one real pixel.
    let cover = clamp((w * 0.5 - d) * s.scale + 0.5, 0.0, 1.0);
    return vec4<f32>(s.color.rgb, cover);
}
