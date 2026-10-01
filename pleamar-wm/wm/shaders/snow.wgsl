// Snow on a window, as if it were a pane in winter: frost creeping in from the
// edges, snow piled up along the top, and flakes stuck to the glass. It is a
// group's shader: `inside(s, at)` is what the window holds.
//
// s.a.x  how much winter: 0 none, 1 all of it (the frost and the snow grow with it)
// s.a.y, s.a.z  how far the window is behind the hand carrying it: the stuck
//        flakes lag a little, the snow on top leans away from the move

fn hash1(p: vec2<f32>) -> f32 {
    let q = fract(p * vec2<f32>(123.34, 456.21));
    let r = q + dot(q, q + 45.32);
    return fract(r.x * r.y);
}

fn hash2(p: vec2<f32>) -> vec2<f32> {
    let a = hash1(p);
    return vec2<f32>(a, hash1(p + a));
}

fn noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash1(i);
    let b = hash1(i + vec2<f32>(1.0, 0.0));
    let c = hash1(i + vec2<f32>(0.0, 1.0));
    let d = hash1(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p: vec2<f32>) -> f32 {
    var v = 0.0;
    var a = 0.5;
    var q = p;
    for (var k = 0; k < 5; k++) {
        v += a * noise(q);
        q = q * 2.03 + vec2<f32>(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

// Frost: how iced a point is, and the lines of its crystals.
fn frost(p: vec2<f32>, size: vec2<f32>, amount: f32) -> vec2<f32> {
    let e = min(min(p.x, p.y), min(size.x - p.x, size.y - p.y));
    // It creeps in from the edges, further at the corners, unevenly.
    let corner = min(min(p.x, size.x - p.x), 200.0) + min(min(p.y, size.y - p.y), 200.0);
    let reach = (14.0 + 40.0 * fbm(p * 0.012)) * amount + 45.0 * amount * (1.0 - smoothstep(0.0, 260.0, corner));
    let ice = 1.0 - smoothstep(reach * 0.35, reach, e + 18.0 * (fbm(p * 0.05) - 0.5));
    // Feathers of ice: ridges of a noise, thin and bright.
    let ridge = 1.0 - abs(fbm(p * 0.09 + vec2<f32>(3.0, 7.0)) * 2.0 - 1.0);
    let lines = pow(ridge, 14.0) * ice;
    return vec2<f32>(ice, lines);
}

// A flake stuck to the glass: a soft six-pointed star, in cells.
fn stuck(p: vec2<f32>, amount: f32) -> f32 {
    let cell = 46.0;
    let g = floor(p / cell);
    var best = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let id = g + vec2<f32>(f32(i), f32(j));
            let h = hash2(id + 31.0);
            if (h.x > 0.05 + 0.18 * amount) { continue; }
            let c = (id + 0.2 + 0.6 * hash2(id + 5.3)) * cell;
            let r = (2.0 + 4.0 * h.y) * amount;
            let q = p - c;
            let a = atan2(q.y, q.x) + h.x * 6.28;
            let star = r * (0.55 + 0.45 * abs(cos(a * 3.0)));
            best = max(best, 1.0 - smoothstep(star * 0.6, star, length(q)));
        }
    }
    return best;
}

fn shade(s: Shader) -> vec4<f32> {
    let amount = clamp(s.a.x, 0.0, 1.0);
    let p = s.pos;
    let base = inside(s, p);
    if (base.a <= 0.001 || amount <= 0.001) { return base; }
    let lag = clamp(s.a.yz, vec2<f32>(-80.0), vec2<f32>(80.0));

    // The glass, cold: a little bluer and paler.
    var c = mix(base.rgb, base.rgb * vec3<f32>(0.92, 0.97, 1.05) + 0.03, 0.5 * amount);

    // Frost: what is behind it, blurred and whitened, with its crystals.
    let f = frost(p, s.size, amount);
    if (f.x > 0.001) {
        var blurred = vec3<f32>(0.0);
        for (var k = 0; k < 8; k++) {
            let a = f32(k) * 0.785;
            let v = inside(s, p + vec2<f32>(cos(a), sin(a)) * 5.0);
            blurred += select(base.rgb, v.rgb, v.a > 0.01);
        }
        blurred = blurred / 8.0;
        let iced = mix(blurred, vec3<f32>(0.86, 0.92, 0.98), 0.45) + vec3<f32>(0.9, 0.95, 1.0) * f.y * 0.6;
        c = mix(c, iced, f.x * 0.8);
    }

    // Flakes stuck to the glass.
    let flake = stuck(p + lag * 0.3, amount);
    c = mix(c, vec3<f32>(0.97, 0.99, 1.0), flake * 0.9);

    // Snow piled up along the top: a bumpy crest, deeper here and there,
    // leaning away from the move when carried, with light on top and a
    // bluish shade underneath.
    let x = p.x - lag.x * 0.15 * (1.0 - p.y / max(s.size.y, 1.0));
    let depth = amount * (8.0 + 14.0 * fbm(vec2<f32>(x * 0.012, 1.3)) + 4.0 * noise(vec2<f32>(x * 0.06, 4.1)));
    let pile = 1.0 - smoothstep(depth - 1.5, depth + 0.5, p.y);
    if (pile > 0.001) {
        let under = smoothstep(depth - 6.0, depth, p.y);
        let sparkle = step(0.985, hash1(floor(p * 0.5))) * 0.3;
        let white = mix(vec3<f32>(0.98, 0.99, 1.0), vec3<f32>(0.72, 0.8, 0.9), under * 0.8) + sparkle;
        c = mix(c, white, pile);
    }
    // And a thin rim of snow down the sides, where the frame catches it.
    let side = min(p.x, s.size.x - p.x);
    let rim = (1.0 - smoothstep(0.0, 2.5 * amount + 0.01, side - 2.0 * noise(vec2<f32>(0.0, p.y * 0.08)))) * amount;
    c = mix(c, vec3<f32>(0.93, 0.96, 1.0), rim * 0.8);

    return vec4<f32>(c, base.a);
}
