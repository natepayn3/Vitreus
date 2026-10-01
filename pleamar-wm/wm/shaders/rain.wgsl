// Rain on a window, as if it were a pane of glass: beads of water that bend
// what the window shows (upside down, as a real drop does), drops that slide
// down leaving a trail, and water gathering along the edges and running down
// the sides. It is a group's shader: `inside(s, at)` is what the window holds.
//
// s.a.x  how much rain: 0 dry, 1 raining (drops come and go with it)
// s.a.y, s.a.z  how far the window is behind the hand carrying it, in pixels:
//        its water lags behind the move and catches up when it stops

fn hash1(p: vec2<f32>) -> f32 {
    let q = fract(p * vec2<f32>(123.34, 456.21));
    let r = q + dot(q, q + 45.32);
    return fract(r.x * r.y);
}

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let a = hash1(p);
    return vec2<f32>(a, hash1(p + a));
}

// A drop at `c` of radius `r` seen from `p`: the vector to its centre in
// radii, and how much of it covers the point (soft at the edge).
struct Bead {
    n: vec2<f32>,
    cover: f32,
};

fn bead(p: vec2<f32>, c: vec2<f32>, r: vec2<f32>) -> Bead {
    var b: Bead;
    b.n = (p - c) / r;
    b.cover = 1.0 - smoothstep(0.82, 1.0, length(b.n));
    return b;
}

// The small still beads that cover the glass: one per cell at most, each
// appearing and drying on its own clock.
fn still(p: vec2<f32>, t: f32, amount: f32, cell: f32, big: f32) -> Bead {
    var best: Bead;
    best.cover = 0.0;
    let g = floor(p / cell);
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let id = g + vec2<f32>(f32(i), f32(j));
            let h = hash2(id + big * 17.0);
            if (h.x > 0.18 + 0.5 * amount) { continue; }
            let c = (id + 0.2 + 0.6 * hash2(id + 7.1)) * cell;
            // It lives a while, then dries, and another comes in its place.
            let life = fract(t / (7.0 + 9.0 * h.y) + h.x * 3.1);
            let grow = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.8, 1.0, life));
            let r = (1.2 + 3.8 * h.y * h.y) * (1.0 + big) * grow;
            if (r < 0.3) { continue; }
            let b = bead(p, c, vec2<f32>(r));
            if (b.cover > best.cover) { best = b; }
        }
    }
    return best;
}

// The big ones that slide: one per column, each at its own pace, speeding up
// as it goes, with a trail of tiny beads left behind.
fn sliding(p: vec2<f32>, size: vec2<f32>, t: f32, amount: f32) -> Bead {
    var best: Bead;
    best.cover = 0.0;
    let column = 70.0;
    let k = floor(p.x / column);
    for (var i = -1; i <= 1; i++) {
        let id = k + f32(i);
        let h = hash2(vec2<f32>(id, 3.7));
        if (h.x > 0.25 + 0.6 * amount) { continue; }
        let period = 4.0 + 7.0 * h.y;
        let phase = fract(t / period + h.x * 5.3);
        let fall = phase * phase;
        let y = -40.0 + fall * (size.y + 80.0);
        let wobble = sin(y * 0.045 + h.x * 20.0) * 6.0 + sin(y * 0.11 + h.y * 9.0) * 2.0;
        let x = (id + 0.3 + 0.4 * h.y) * column + wobble;
        let r = 5.5 + 4.5 * h.x;
        // Heavier at the bottom: a drop leans on what is under it.
        var b = bead(p, vec2<f32>(x, y), vec2<f32>(r * 0.85, r * 1.15));
        if (b.cover > best.cover) { best = b; }
        // The trail: tiny beads where it has just been.
        let above = y - p.y;
        if (above > r && above < 220.0) {
            let step = 9.0;
            let m = floor(p.y / step);
            let ty = (m + 0.5) * step;
            let tw = sin(ty * 0.045 + h.x * 20.0) * 6.0 + sin(ty * 0.11 + h.y * 9.0) * 2.0;
            let tx = (id + 0.3 + 0.4 * h.y) * column + tw + (hash1(vec2<f32>(m, id)) - 0.5) * 3.0;
            let tr = (1.0 + 1.3 * hash1(vec2<f32>(id, m))) * (1.0 - above / 220.0);
            let tb = bead(p, vec2<f32>(tx, ty), vec2<f32>(tr));
            if (tb.cover > best.cover) { best = tb; }
        }
    }
    return best;
}

fn shade(s: Shader) -> vec4<f32> {
    let amount = clamp(s.a.x, 0.0, 1.0);
    let p = s.pos;
    let t = s.time;
    let base = inside(s, p);
    if (base.a <= 0.001 || amount <= 0.001) { return base; }

    // Water gathering along the edges: a wavy line that beads and runs.
    let e = min(min(p.x, p.y), min(s.size.x - p.x, s.size.y - p.y));
    let along = select(p.x, p.y, min(p.x, s.size.x - p.x) < min(p.y, s.size.y - p.y));
    let swell = 2.5 + 5.0 * (0.5 + 0.5 * sin(along * 0.13 + t * 1.7)) * (0.5 + 0.5 * sin(along * 0.037 - t * 0.9));
    var rim = bead(vec2<f32>(e, 0.0), vec2<f32>(0.0), vec2<f32>(swell * amount + 0.01, 1.0));
    rim.n = vec2<f32>(0.0, rim.n.x);

    // Drips running down the sides.
    var drip: Bead;
    drip.cover = 0.0;
    for (var side = 0; side < 2; side++) {
        let x = select(3.0, s.size.x - 3.0, side == 1);
        for (var k = 0; k < 3; k++) {
            let h = hash2(vec2<f32>(f32(k), f32(side) + 11.0));
            let y = fract(t / (3.0 + 4.0 * h.x) + h.y) * (s.size.y + 60.0) - 30.0;
            let b = bead(p, vec2<f32>(x, y), vec2<f32>(3.2, 4.5) * amount);
            if (b.cover > drip.cover) { drip = b; }
        }
    }

    // Carried, the water lags behind the move: the heavier, the more.
    let lag = clamp(s.a.yz, vec2<f32>(-80.0), vec2<f32>(80.0));
    var b = still(p + lag * 0.25, t, amount, 24.0, 0.0);
    // A few bigger ones, further apart.
    let fat = still(p + lag * 0.45, t * 0.6, amount * 0.5, 70.0, 1.2);
    if (fat.cover > b.cover) { b = fat; }
    let big = sliding(p + lag * 0.6, s.size, t, amount);
    if (big.cover > b.cover) { b = big; }
    if (drip.cover > b.cover) { b = drip; }
    if (rim.cover > b.cover) { b = rim; }

    // The glass itself, a little wet: cooler and a touch darker.
    var c = mix(base.rgb, base.rgb * vec3<f32>(0.9, 0.95, 1.0), 0.35 * amount);
    if (b.cover > 0.001) {
        let d = length(b.n);
        // A drop is a lens: what is behind comes through it bent, and upside down.
        let r = inside(s, p - b.n * 14.0);
        var seen = select(base.rgb, r.rgb, r.a > 0.01);
        // Its edge is dark (the light leaves sideways)…
        let edge = smoothstep(0.55, 1.0, d);
        seen = seen * (1.0 - 0.6 * edge) + 0.05;
        // …the light that comes through gathers at the bottom, a crescent…
        let crescent = smoothstep(0.45, 0.9, d) * (1.0 - smoothstep(0.9, 1.0, d)) * smoothstep(0.0, 0.8, b.n.y);
        seen = seen + vec3<f32>(0.75, 0.82, 0.9) * crescent * 0.55;
        // …and its top catches the window's light: a glint.
        let glint = pow(max(0.0, 1.0 - length(b.n - vec2<f32>(-0.3, -0.45)) * 2.4), 2.0);
        seen = seen + vec3<f32>(1.0) * glint * 0.9;
        c = mix(c, seen, b.cover);
    }
    return vec4<f32>(c, base.a);
}
