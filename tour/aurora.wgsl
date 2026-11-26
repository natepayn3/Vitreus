// The tour's backdrop: a deep dim, darker at the edges, with a hint of the shell's accent drifting in it, a soft halo where the card is,
// and a scatter of faint specks that twinkle. Worked out from the point and the time alone.
//
// s.a.x how far the tour has come in (0..1) · s.a.y the step, as it travels (the light drifts a little with each card)
// s.a.z, s.a.w the card's middle, in pixels of the box
// s.color the accent · s.color2 the second accent

fn hsh(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hsh(i), hsh(i + vec2<f32>(1.0, 0.0)), u.x), mix(hsh(i + vec2<f32>(0.0, 1.0)), hsh(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

fn fbm(p0: vec2<f32>) -> f32 {
    var p = p0;
    var v = 0.0;
    var a = 0.5;
    for (var i = 0; i < 4; i = i + 1) {
        v = v + a * vnoise(p);
        p = p * 2.03 + vec2<f32>(1.7, 9.2);
        a = a * 0.5;
    }
    return v;
}

fn shade(s: Shader) -> vec4<f32> {
    let k = clamp(s.a.x, 0.0, 1.0);
    let t = s.time * 0.06 + s.a.y * 0.35;
    let asp = s.size.x / max(s.size.y, 1.0);
    let p = vec2<f32>(s.uv.x * asp, s.uv.y);

    // Curtains: bands that hang from the top and sway, broken up by noise.
    let warp = fbm(vec2<f32>(p.x * 1.3 + t, t * 0.7)) * 1.4;
    let band1 = exp(-pow((p.y - 0.30 - 0.18 * sin(p.x * 1.7 + warp * 2.0 + t * 3.0)) * 4.2, 2.0));
    let band2 = exp(-pow((p.y - 0.62 - 0.14 * sin(p.x * 2.3 - warp * 2.4 - t * 2.2)) * 5.0, 2.0));
    let rays = 0.55 + 0.45 * fbm(vec2<f32>(p.x * 7.0 + warp * 3.0, t * 2.0));
    let c1 = s.color.rgb * band1 * rays;
    let c2 = s.color2.rgb * band2 * (1.1 - rays * 0.4);

    // The bloom behind the card.
    let d = length((s.pos - vec2<f32>(s.a.z, s.a.w)) / vec2<f32>(s.size.y * 0.55, s.size.y * 0.42));
    let bloom = exp(-d * d * 1.6) * 0.55;

    // Specks: one in a cell here and there, each twinkling on its own.
    let cell = floor(s.pos / 46.0);
    let r = hsh(cell + 7.0);
    let sp = fract(s.pos / 46.0) - vec2<f32>(hsh(cell + 1.3), hsh(cell + 5.1));
    let tw = 0.5 + 0.5 * sin(s.time * (1.0 + r * 2.0) + r * 40.0);
    let speck = select(0.0, exp(-dot(sp, sp) * 2400.0) * tw, r > 0.86);

    // A dim first: the screen is taken down, darker towards its edges, so the card stands out. The light is only a hint in it: faint curtains,
    // a soft halo round the card, and the specks.
    let light = c1 * 0.10 + c2 * 0.08 + mix(s.color.rgb, s.color2.rgb, 0.5) * bloom * 0.22 + vec3<f32>(speck * 0.35);
    let base = vec3<f32>(0.01, 0.012, 0.018);
    let rgb = base + light;
    let edge = length((s.uv - vec2<f32>(0.5, 0.5)) * vec2<f32>(1.0, 0.9));
    let a = clamp(0.74 + 0.22 * smoothstep(0.25, 0.75, edge) - bloom * 0.12, 0.0, 0.96) * k;
    return vec4<f32>(rgb, a);
}
