// The fill inside the shell's pencil shapes when Settings > Style > Fill is not Pencil (that one is pencilhatch.wgsl): the level of a slider, a picker's
// thumb, the sidebar's thumb, a switch that is on. A rounded bar from x0 to x1 (in the box, from its left edge), hh tall about the box's middle, filled as
//   1 Marker   broad felt-tip strokes laid side by side on a slant, darker where two overlap and where the ink pools at the edge, streaked along each stroke
//   2 Gradient the colour rising from faint at the start to strong at the level's end, with a soft light along the top
//   3 Plain    one flat wash
//   4 Dots     halftone dots on a staggered grid, growing towards the end
// Its edge wobbles with the pencil (`jt`, moving with the frame `fr`), so it boils with the outline round it.
//
// values: x0, x1, hh, corner · mode (1 to 4), fr, jt, k (the unit: the texture's size)
// colors: the fill's colour

fn fs_hash(n: f32) -> f32 {
    return fract(sin(n * 127.1 + 11.7) * 43758.5453);
}

fn shade(s: Shader) -> vec4<f32> {
    let x0 = s.a.x;
    let x1 = s.a.y;
    let hh = max(s.a.z, 0.5);
    let mode = u32(round(s.b.x));
    let fr = s.b.y - 64.0 * floor(s.b.y / 64.0);
    let jt = s.b.z;
    let k = max(s.b.w, 0.1);
    if (x1 <= x0 || mode == 0u) {
        return vec4<f32>(0.0);
    }
    let p = s.pos;
    let mid = s.size.y * 0.5;
    let r = clamp(s.a.w, 0.0, min(hh * 0.5, (x1 - x0) * 0.5));
    // The rounded bar's distance (negative inside), its edge moved a little by the pencil's wobble.
    let c = vec2<f32>((x0 + x1) * 0.5, mid);
    let half = vec2<f32>((x1 - x0) * 0.5, hh * 0.5);
    let q = abs(p - c) - half + vec2<f32>(r, r);
    var d = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
    d = d + jt * (0.6 * sin(p.x * 0.9 / k + fr * 1.7) + 0.4 * sin(p.y * 1.3 / k + fr * 2.3 + 1.1));
    let cover = clamp(-d * s.scale + 0.5, 0.0, 1.0);
    if (cover <= 0.0) {
        return vec4<f32>(0.0);
    }
    let t = clamp((p.x - x0) / max(x1 - x0, 0.001), 0.0, 1.0);
    var col = s.color.rgb;
    var a = 0.0;
    if (mode == 1u) {
        // Strokes on a slant, each wider than the step between them, so every point is under one or two.
        let sp = max(hh * 0.62, 2.0 * k);
        let wd = sp * 1.45;
        let u = (p.x - x0) + (p.y - mid) * 0.42;
        let base = floor(u / sp);
        var clear = 1.0;
        for (var i = -1; i <= 1; i = i + 1) {
            let idx = base + f32(i);
            let cu = idx * sp + sp * 0.5 + (fs_hash(idx + fr * 0.13) - 0.5) * sp * 0.25 * min(jt / k + 0.3, 1.5);
            let off = abs(u - cu);
            let edge = clamp((wd * 0.5 - off) * s.scale + 0.5, 0.0, 1.0);
            // streaks along the stroke: the felt leaves lighter lines where it skips
            let v = (p.y - mid) / hh;
            let streak = 0.82 + 0.18 * sin((off / k) * 2.7 + fs_hash(idx) * 6.28) * (0.6 + 0.4 * sin(v * 9.0 + idx));
            clear = clear * (1.0 - 0.5 * streak * edge);
        }
        a = 1.0 - clear;
        // the ink pools a little darker just inside the edge
        a = min(1.0, a + 0.28 * clamp(1.0 + d / (1.4 * k), 0.0, 1.0));
    } else if (mode == 2u) {
        a = mix(0.22, 0.95, t * t * (3.0 - 2.0 * t));
        let top = clamp((mid - p.y) / (hh * 0.5), 0.0, 1.0);
        col = mix(col, vec3<f32>(1.0), 0.28 * top * top);
    } else if (mode == 3u) {
        a = 0.8;
    } else {
        let g = 3.4 * k;
        let row = floor(p.y / (g * 0.866));
        let sx = p.x + select(0.0, g * 0.5, (row - 2.0 * floor(row / 2.0)) > 0.5);
        let cc = vec2<f32>((floor(sx / g) + 0.5) * g, (row + 0.5) * g * 0.866);
        let dd = length(vec2<f32>(sx, p.y) - cc);
        let rad = g * 0.5 * (0.3 + 0.62 * t);
        a = clamp((rad - dd) * s.scale + 0.5, 0.0, 1.0) * 0.95;
    }
    return vec4<f32>(col, a * cover);
}
