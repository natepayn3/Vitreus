// The dotted leader in Settings: a row of pencil dots from the end of a setting's name to its control (a switch, a slider, a picker), so the eye can follow
// the one to the other across the gap, as in a book's contents. The dots are laid from the right end (the control's edge) leftwards, so they stop neatly
// at the control whatever the name's length. Each dot is a little blob, not a circle: squashed and turned a bit by the pencil, and drawn again while
// `fr` moves; the faint second pass (the echo) sits a hair off, as every pencil line in the shell has.
//
// values: gap (between dots), r (a dot's radius), jt (the pencil's wobble), fr (its frame) · echo (the second pass's strength), k (the unit), -, -
// colors: the dots' colour

fn ld_hash(n: f32) -> f32 {
    return fract(sin(n * 91.7 + 3.1) * 43758.5453);
}

fn ld_dot(p: vec2<f32>, c: vec2<f32>, r: f32, idx: f32, fr: f32, jt: f32, scale: f32) -> f32 {
    let f = fr - 64.0 * floor(fr / 64.0);
    let a = ld_hash(idx * 1.3 + f * 0.71) * 3.14159;
    let sq = 1.0 + 0.35 * ld_hash(idx * 2.9 + f * 0.37) * min(jt * 2.0 + 0.3, 1.0);
    let off = vec2<f32>(ld_hash(idx * 5.1 + f) - 0.5, ld_hash(idx * 7.3 + f * 1.3) - 0.5) * jt * 2.0;
    let d = p - c - off;
    let rot = vec2<f32>(d.x * cos(a) + d.y * sin(a), -d.x * sin(a) + d.y * cos(a));
    let e = length(vec2<f32>(rot.x / sq, rot.y * sq));
    return clamp((r - e) * scale + 0.5, 0.0, 1.0);
}

fn shade(s: Shader) -> vec4<f32> {
    let gap = max(s.a.x, 1.0);
    let r = s.a.y;
    let jt = s.a.z;
    let fr = s.a.w;
    let echo = s.b.x;
    let k = s.b.y;
    let p = s.pos;
    let mid = s.size.y * 0.5;
    let right = s.size.x - r - 1.0;
    // the dot nearest this point, counting from the right end
    let idx = round((right - p.x) / gap);
    if (idx < 0.0) {
        return vec4<f32>(0.0);
    }
    let cx = right - idx * gap;
    if (cx < r + 1.0) {
        return vec4<f32>(0.0);
    }
    let main = ld_dot(p, vec2<f32>(cx, mid), r, idx, fr, jt, s.scale);
    let ghost = ld_dot(p, vec2<f32>(cx + 0.35 * k, mid + 0.3 * k), r * 0.8, idx + 40.0, fr, jt, s.scale) * 0.35 * echo;
    let a = max(main, ghost);
    return vec4<f32>(s.color.rgb, a);
}
