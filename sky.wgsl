// The calendar's weather card: the sky outside, alive. Everything is worked out from where the point is and the time, so it costs
// what its pixels cost and nothing while the card is hidden.
//
// s.a.x cloud cover (0..1) · s.a.y rain · s.a.z snow · s.a.w fog in thousandths, plus the storm as the fraction
// s.b.x the clock (seconds; the scene's `sk.t`) · s.b.y daylight (0 night, 1 day, between: twilight)
// s.b.z where the sun is between sunrise and sunset, in thousandths, plus the moon's phase as the fraction (0 new, 0.5 full)
// s.b.w the theme and the wind, packed: neon*1000 + sketch*100 + plastic*10 + wind (each 0..9); negative when the wind blows to the left
// s.color the accent · s.color2 the ink (the text drawn over it)

fn hsh(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 = p3 + dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn vnoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hsh(i);
    let b = hsh(i + vec2<f32>(1.0, 0.0));
    let c = hsh(i + vec2<f32>(0.0, 1.0));
    let d = hsh(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm(p0: vec2<f32>) -> f32 {
    var p = p0;
    var v = 0.0;
    var a = 0.5;
    for (var i = 0; i < 5; i = i + 1) {
        v = v + a * vnoise(p);
        p = vec2<f32>(p.x * 1.6 + p.y * 1.2, -p.x * 1.2 + p.y * 1.6) + vec2<f32>(3.1, 1.7);
        a = a * 0.5;
    }
    return v;
}

fn luma(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.299, 0.587, 0.114)); }

// Rain: thin streaks falling at a slant, in columns that each have their own pace.
fn rain_layer(px: vec2<f32>, t: f32, L: f32, slant: f32, amount: f32) -> f32 {
    let cw = 6.0 + L * 5.0;
    let v = 420.0 + L * 260.0;
    let len = 10.0 + L * 9.0;
    var p = px;
    p.x = p.x + p.y * slant;
    let col = floor(p.x / cw);
    let r = hsh(vec2<f32>(col, L * 17.0 + 3.0));
    let r2 = hsh(vec2<f32>(col, L * 17.0 + 9.0));
    if (r2 > amount * (0.55 + L * 0.2)) { return 0.0; }
    let period = 70.0 + r * 90.0;
    let yy = (p.y - t * v * (0.8 + 0.4 * r) - r * 911.0) - period * floor((p.y - t * v * (0.8 + 0.4 * r) - r * 911.0) / period);
    let streak = smoothstep(0.0, len, yy) * step(yy, len);
    let xo = (0.2 + 0.6 * hsh(vec2<f32>(col, 5.0 + L))) * cw;
    let dx = abs(p.x - col * cw - xo);
    return streak * smoothstep(0.6 + L * 0.35, 0.0, dx) * (0.35 + 0.25 * L);
}

// Snow: soft flakes drifting down and swaying.
fn snow_layer(px: vec2<f32>, t: f32, L: f32, drift: f32) -> f32 {
    let cell = 22.0 + L * 12.0;
    let speed = 14.0 + L * 13.0;
    let p = px + vec2<f32>(-t * drift * 60.0 * (1.0 + L * 0.5), -t * speed);
    let c = floor(p / cell);
    let f = p - c * cell;
    let r = hsh(c + vec2<f32>(L * 31.0, L * 7.0));
    if (r < 0.3) { return 0.0; }
    let ctr = vec2<f32>(0.2 + 0.6 * hsh(c + vec2<f32>(1.3, 7.1)), 0.2 + 0.6 * hsh(c + vec2<f32>(5.7, 2.9))) * cell
        + vec2<f32>(sin(t * (0.7 + r) + r * 6.283) * cell * 0.18, 0.0);
    let rad = 0.9 + L * 0.75 + r * 0.7;
    return smoothstep(rad, rad * 0.25, length(f - ctr)) * (0.55 + 0.2 * L);
}

fn stars(px: vec2<f32>, t: f32, cell: f32, seed: f32) -> f32 {
    let c = floor(px / cell);
    let f = px - c * cell;
    let r = hsh(c + vec2<f32>(seed, seed * 2.0));
    if (r < 0.72) { return 0.0; }
    let ctr = vec2<f32>(0.15 + 0.7 * hsh(c + vec2<f32>(seed + 3.0, 1.0)), 0.15 + 0.7 * hsh(c + vec2<f32>(seed + 8.0, 4.0))) * cell;
    let d = length(f - ctr);
    let tw = 0.55 + 0.45 * sin(t * (1.3 + 3.0 * r) + r * 40.0);
    let size = 0.6 + 1.1 * (r - 0.72) / 0.28;
    return smoothstep(size + 0.8, 0.0, d) * tw;
}

fn shade(s: Shader) -> vec4<f32> {
    let W = s.size.x;
    let H = s.size.y;
    let uv = s.uv;
    let px = s.pos;
    let t = s.b.x;
    let pi = 3.14159265;

    let cl = clamp(s.a.x, 0.0, 1.0);
    let rn = clamp(s.a.y, 0.0, 1.0);
    let sn = clamp(s.a.z, 0.0, 1.0);
    let fg = clamp(floor(s.a.w) / 999.0, 0.0, 1.0);
    let st = clamp(fract(s.a.w), 0.0, 1.0);
    let dl = clamp(s.b.y, 0.0, 1.0);
    let sunp = clamp(floor(s.b.z) / 1000.0, 0.0, 1.0);
    let moon = fract(s.b.z);
    let pk = abs(s.b.w);
    let neon = floor(pk / 1000.0) / 9.0;
    let sketch = floor(fract(pk / 1000.0) * 10.0 + 0.001) / 9.0;
    let plastic = floor(fract(pk / 100.0) * 10.0 + 0.001) / 9.0;
    let windq = floor(fract(pk / 10.0) * 10.0 + 0.001) / 9.0;
    let wsign = select(1.0, -1.0, s.b.w < 0.0);
    let drift = wsign * (0.010 + 0.05 * windq);
    let unit = H / 390.0;               // the card is about 390 px tall at the usual size: what is measured in px grows with it

    // a little parallax with the pointer while it is over the card
    let par = (s.pointer - s.size * 0.5) / s.size * s.hovered;

    // ── the sky's colour: night, day, and the gold of sunrise and sunset ──
    let golden = clamp(max(dl * (1.0 - smoothstep(0.02, 0.22, min(sunp, 1.0 - sunp))), 1.25 * (1.0 - abs(2.0 * dl - 1.0))), 0.0, 1.0);
    var top = mix(vec3<f32>(0.015, 0.025, 0.08), vec3<f32>(0.16, 0.40, 0.80), dl);
    var hor = mix(vec3<f32>(0.07, 0.11, 0.25), vec3<f32>(0.50, 0.74, 0.95), dl);
    top = mix(top, vec3<f32>(0.30, 0.22, 0.52), golden * 0.8);
    hor = mix(hor, vec3<f32>(1.0, 0.52, 0.30), golden * 0.92);
    let midg = exp(-pow((uv.y - 0.62) * 3.0, 2.0)) * golden;            // the band of pink between the gold and the blue
    let ov = clamp(cl * 0.7 + rn * 0.35 + st * 0.5 + fg * 0.45 + sn * 0.2, 0.0, 1.0);
    top = mix(top, vec3<f32>(luma(top)) * mix(1.0, 0.65, st), ov * 0.8);
    hor = mix(hor, vec3<f32>(luma(hor)) * mix(1.05, 0.7, st), ov * 0.75);
    var sky = mix(top, hor, pow(uv.y, 0.85));
    sky = mix(sky, vec3<f32>(0.92, 0.45, 0.50), midg * 0.35 * (1.0 - ov));

    // ── the sun, along its arc from sunrise (left) to sunset (right) ──
    let sp = vec2<f32>(mix(0.06, 0.94, sunp) * W, (0.64 - 0.50 * sin(pi * sunp)) * H) - par * 6.0;
    let R = 17.0 * unit;
    let ds = length(px - sp);
    let sunvis = dl * (1.0 - 0.8 * smoothstep(0.35, 1.0, cl)) * (1.0 - 0.9 * st);
    let suncol = mix(vec3<f32>(1.0, 0.93, 0.72), vec3<f32>(1.0, 0.60, 0.30), golden);
    let ang = atan2(px.y - sp.y, px.x - sp.x);
    let rays = pow(0.5 + 0.5 * sin(ang * 11.0 + t * 0.22), 10.0) * 0.5 + pow(0.5 + 0.5 * sin(ang * 7.0 - t * 0.15 + 1.0), 12.0) * 0.4;
    let sglow = exp(-ds / (R * 1.6)) * 0.55 + exp(-ds / (R * 6.0)) * 0.28 + rays * exp(-ds / (R * 4.0)) * 0.45 * (1.0 - cl);
    sky = sky + suncol * sglow * sunvis;
    let sdisc = smoothstep(R + 1.2, R - 1.2, ds) * (0.92 + 0.08 * sin(t * 1.7));
    sky = mix(sky, mix(vec3<f32>(1.0, 0.98, 0.9), suncol, 0.35), sdisc * sunvis);

    // ── the night: stars, and the moon in tonight's phase ──
    let nv = (1.0 - dl) * (1.0 - smoothstep(0.3, 0.95, cl)) * (1.0 - st);
    let st_amt = (stars(px + par * 3.0, t, 19.0 * unit, 1.0) + stars(px + par * 2.0 + vec2<f32>(7.0, 3.0), t, 11.0 * unit, 9.0) * 0.6) * (1.0 - 0.8 * uv.y);
    sky = sky + vec3<f32>(0.9, 0.93, 1.0) * st_amt * nv;
    let mp = vec2<f32>(0.54 * W, 0.17 * H) - par * 5.0;
    let Rm = 14.0 * unit;
    let q = (px - mp) / Rm;
    let dm = length(q);
    let mdisc = smoothstep(1.0 + 1.5 / Rm, 1.0 - 1.5 / Rm, dm);
    let yy = clamp(q.y, -1.0, 1.0);
    let edge = sqrt(max(0.0, 1.0 - yy * yy)) * cos(2.0 * pi * moon);
    let lit = select(smoothstep(-edge - 0.06, -edge + 0.06, -q.x), smoothstep(edge - 0.06, edge + 0.06, q.x), moon < 0.5);
    let crater = 1.0 - 0.18 * smoothstep(0.55, 0.75, vnoise(q * 3.0 + vec2<f32>(4.0, 2.0)));
    let mcol = mix(vec3<f32>(0.10, 0.12, 0.20), vec3<f32>(0.96, 0.94, 0.86) * crater, lit);
    let mvis = (1.0 - dl) * (1.0 - 0.75 * smoothstep(0.4, 1.0, cl)) * (1.0 - 0.8 * st);
    sky = sky + vec3<f32>(0.75, 0.8, 1.0) * exp(-max(dm - 1.0, 0.0) * 2.2) * 0.22 * mvis * (0.4 + 0.6 * (1.0 - abs(moon - 0.5) * 2.0));
    sky = mix(sky, mcol, mdisc * mvis);

    // ── the clouds: two layers drifting with the wind, lit from the sun's side ──
    let sundir = normalize(vec2<f32>(sp.x - px.x, sp.y - px.y) + vec2<f32>(0.001, 0.001));
    var cloudshadow = 0.0;
    var cline = 0.0;                    // (the sketch: where a cloud's edge is, for the ink line round it)
    var cunder = 0.0;                   // (and how much of a cloud is its shaded underside)
    for (var l = 0; l < 2; l = l + 1) {
        let L = f32(l);
        let sc = 2.6 + L * 1.9;
        let qc = vec2<f32>(uv.x * W / H, uv.y * 1.35) * sc + vec2<f32>(t * drift * (1.0 + L * 0.7) * sc, L * 13.7) + par * (0.08 + L * 0.06);
        let n = fbm(qc);
        let th = mix(0.80, 0.30, cl) + L * 0.04;
        let dens = smoothstep(th, th + 0.24 - 0.08 * st, n) * mix(1.0, 0.55, uv.y * (1.0 - cl * 0.6));
        let n2 = fbm(qc + sundir * 0.18);
        let lightk = clamp((n - n2) * 4.0 + 0.62, 0.0, 1.0);
        let dayc = mix(vec3<f32>(0.58, 0.62, 0.70), vec3<f32>(1.0, 1.0, 1.0), lightk);
        let stormc = mix(vec3<f32>(0.16, 0.17, 0.22), vec3<f32>(0.42, 0.44, 0.50), lightk);
        let nightc = mix(vec3<f32>(0.06, 0.07, 0.12), vec3<f32>(0.22, 0.25, 0.34), lightk);
        var cc = mix(nightc, mix(dayc, stormc, clamp(st + rn * 0.4, 0.0, 1.0)), dl);
        cc = cc + vec3<f32>(1.0, 0.55, 0.35) * golden * lightk * 0.35;
        cc = cc + suncol * exp(-ds / (R * 3.5)) * sunvis * 0.5;              // the edge of a cloud that crosses the sun shines
        let a = dens * (0.92 - L * 0.12);
        sky = mix(sky, cc, a);
        cloudshadow = max(cloudshadow, a);
        let lth = th + 0.1;                                                    // the ink goes round the cloud where its noise crosses this, one pixel or so wide
        let fw = max(fwidth(n), 0.0005) * 1.3;
        let ln = (1.0 - smoothstep(0.0, fw, abs(n - lth))) * select(0.55, 1.0, l == 0);
        cline = max(cline * (1.0 - a * 0.9), ln * mix(1.0, 0.5, cl));
        cunder = mix(cunder, (1.0 - lightk) * smoothstep(0.4, 0.8, dens), a);
    }

    // ── fog: slow bands low down ──
    let fb = fbm(vec2<f32>(uv.x * 2.2 + t * 0.025 * wsign, uv.y * 5.0 - t * 0.01));
    let fogk = fg * (0.25 + 0.75 * smoothstep(0.0, 0.9, uv.y)) * (0.45 + 0.75 * fb);
    sky = mix(sky, mix(vec3<f32>(0.20, 0.22, 0.28), vec3<f32>(0.80, 0.82, 0.85), dl), clamp(fogk, 0.0, 0.85));

    // ── storm: the sky lights up, and now and then a bolt ──
    let per = 4.7;
    let seg = floor(t / per);
    let lt = t - seg * per;
    let rr = hsh(vec2<f32>(seg, 3.3));
    let on = step(0.3, rr) * st;
    let flash = (exp(-lt * 10.0) + step(0.13, lt) * exp(-max(lt - 0.13, 0.0) * 13.0) * 0.8) * on;
    let bx = (0.18 + 0.64 * hsh(vec2<f32>(seg, 7.7))) * W + (fbm(vec2<f32>(uv.y * 4.0, seg * 1.3)) - 0.5) * W * 0.22 + (vnoise(vec2<f32>(uv.y * 26.0, seg * 3.1)) - 0.5) * W * 0.035;
    let bend = 0.35 + 0.45 * hsh(vec2<f32>(seg, 9.1));
    let bd = abs(px.x - bx);
    let bolt = (smoothstep(1.6 * unit, 0.0, bd) + exp(-bd / (9.0 * unit)) * 0.5) * step(uv.y, bend) * smoothstep(bend, bend - 0.08, uv.y);
    sky = sky + vec3<f32>(0.75, 0.8, 1.0) * flash * (0.35 + 0.4 * cloudshadow) + vec3<f32>(0.9, 0.92, 1.0) * bolt * flash * 1.4;

    // ── rain and snow, in front of everything ──
    let slant = -0.18 * drift / 0.06;
    var rainv = 0.0;
    for (var l = 0; l < 3; l = l + 1) { rainv = rainv + rain_layer(px + vec2<f32>(par.x * f32(l) * 4.0, 0.0), t, f32(l), slant, rn); }
    var snowv = 0.0;
    for (var l = 0; l < 3; l = l + 1) { snowv = snowv + snow_layer(px + par * f32(l) * 5.0, t, f32(l), drift); }
    let pcol = mix(vec3<f32>(0.55, 0.62, 0.78), vec3<f32>(0.86, 0.91, 1.0), dl * 0.7 + 0.3);
    sky = mix(sky, pcol, clamp(rainv * rn, 0.0, 0.85));
    sky = mix(sky, vec3<f32>(0.97, 0.98, 1.0), clamp(snowv * sn, 0.0, 0.95));

    // ── legibility: the text drawn over it is the theme's ink; keep the sky on the other side of it ──
    let ink = s.color2.rgb;
    let il = luma(ink);
    let lightink = smoothstep(0.42, 0.58, il);
    // the sky's brightness is squeezed to the far side of the ink's: light words get a sky no brighter than about 0.55, dark words one no darker than about 0.8
    let L0 = max(luma(sky), 0.001);
    let Ldark = min(L0, 0.12 + L0 * 0.6) * mix(0.75, 1.0, smoothstep(0.0, 0.62, uv.x));     // (a little deeper behind the big temperature)
    let Llight = 0.80 + 0.20 * L0;
    let Lt = mix(Llight, Ldark, lightink);
    var glass = mix(vec3<f32>(Lt), sky * (Lt / L0), mix(0.75, 1.0, lightink));
    glass = clamp(glass, vec3<f32>(0.0), vec3<f32>(1.0));
    // rain and snow drawn again over it, in the ink with a touch of the accent: the colour the sky was just kept away from, so they always show
    let pc = mix(s.color2.rgb, s.color.rgb, 0.35);
    glass = mix(glass, pc, clamp(rainv * rn * 1.25, 0.0, 0.8));
    glass = mix(glass, mix(vec3<f32>(1.0), pc, 0.55 * (1.0 - lightink)), clamp(snowv * sn * 1.1, 0.0, 0.95));

    // ── the themes ──
    // plastic (Retro, UwU): a screen print. Five flat bands of light, cut from the sky before it was made legible, each in the sky's own colour
    // (not greyed out), kept on the ink's far side; clouds come out as flat shapes, and rain and snow are drawn in the ink so they show on a pale sky.
    let lb = floor(L0 * 5.0 + 0.5) / 5.0;
    let ltq = mix(0.74 + 0.26 * lb, min(lb, 0.10 + lb * 0.6), lightink);
    let hue2 = sky / max(max(sky.r, max(sky.g, sky.b)), 0.05);
    var poster = mix(vec3<f32>(ltq), hue2 * (ltq / max(luma(hue2), 0.05)), 0.5);
    poster = clamp(poster, vec3<f32>(0.0), vec3<f32>(1.0));
    poster = mix(poster, ink, clamp(rainv * rn * 0.7, 0.0, 0.35) + clamp(st_amt * nv, 0.0, 0.5) * lightink);
    poster = mix(poster, mix(vec3<f32>(1.0), ink, 0.25 * (1.0 - lightink)), clamp(snowv * sn, 0.0, 0.9));
    var col = mix(glass, poster, plastic);
    // sketch (Doodle, Paper): a page of the sketchbook. Pale washes of the sky's colour on paper, white clouds with the ink round
    // their edges and pencil hatching only under them, a yellow sun with an inked rim and rays, rain as short ink dashes.
    let paperc = vec3<f32>(0.995, 0.985, 0.94);
    let hue = sky / max(max(sky.r, max(sky.g, sky.b)), 0.05);              // the sky's colour at full brightness
    var sk = mix(paperc, paperc * mix(vec3<f32>(1.0), hue, 0.35), 0.5 + 0.5 * dl) * mix(0.62, 1.0, dl);
    let grain = (vnoise(px * 0.9) - 0.5) * 0.035 + (vnoise(px * vec2<f32>(0.05, 1.3)) - 0.5) * 0.02;
    sk = sk + vec3<f32>(grain);
    let cloudpaper = mix(vec3<f32>(0.80, 0.80, 0.84), vec3<f32>(1.0, 0.995, 0.97), dl) * mix(1.0, 0.78, st);
    sk = mix(sk, cloudpaper, cloudshadow * 0.95);
    let hatch = step(0.62, fract((px.x + px.y) / (4.5 * unit))) * smoothstep(0.25, 0.6, cunder)
              + step(0.62, fract((px.x - px.y) / (4.5 * unit))) * smoothstep(0.55, 0.9, cunder) * st;
    sk = mix(sk, ink, clamp(hatch, 0.0, 1.0) * 0.28 * cloudshadow);
    sk = mix(sk, ink, clamp(cline, 0.0, 1.0) * 0.75);
    // the sun: butter yellow, an inked rim and eight short rays; the moon: paper with an inked rim
    let sunfill = smoothstep(R + 1.0, R - 1.0, ds) * sunvis * (1.0 - cloudshadow);
    sk = mix(sk, vec3<f32>(0.99, 0.90, 0.52), sunfill);
    let rayang = fract(ang / (2.0 * pi) * 8.0 + t * 0.02);
    let ray = smoothstep(0.08, 0.0, abs(rayang - 0.5) * (ds / R)) * step(R * 1.35, ds) * step(ds, R * 1.9) * sunvis * (1.0 - cloudshadow);
    let ringd = abs(ds - R);
    sk = mix(sk, ink, (smoothstep(1.4 * unit, 0.4 * unit, ringd) * sunvis * (1.0 - cloudshadow) + ray) * 0.85);
    sk = mix(sk, mix(sk, paperc, lit), mdisc * mvis);
    sk = mix(sk, ink, smoothstep(1.4 / Rm, 0.4 / Rm, abs(dm - 1.0)) * mvis * 0.85);
    sk = mix(sk, ink, clamp(st_amt * nv * 2.0, 0.0, 0.7));
    sk = mix(sk, ink, clamp(rainv * rn * 1.3, 0.0, 0.75));
    sk = mix(sk, ink, clamp(snowv * sn, 0.0, 1.0) * 0.18);               // snow: paper flakes with a faint line
    sk = mix(sk, vec3<f32>(0.99, 0.90, 0.52), bolt * flash * 0.9);
    sk = mix(sk, paperc + vec3<f32>(grain), smoothstep(0.70, 0.80, uv.y) * 0.75);     // the week sits on plain paper
    col = mix(col, sk, sketch);
    // neon (Cyber, Proxy): the sky as a readout in the accent: dark, scanned, its lights in the accent
    let acc = s.color.rgb;
    let nl = luma(sky);
    var ne = mix(vec3<f32>(0.0), acc * 0.55, smoothstep(0.05, 0.9, nl)) + acc * (sglow * sunvis + st_amt * nv + rainv * rn * 0.8 + snowv * sn * 0.8 + bolt * flash);
    ne = ne * (0.82 + 0.18 * step(0.5, fract(px.y / (3.0 * unit))));
    let grid = max(step(fract(px.x / (24.0 * unit)), 0.04), step(fract(px.y / (24.0 * unit)), 0.04)) * 0.06 * (1.0 - nl);
    ne = ne + acc * grid;
    col = mix(col, ne, neon);

    // the card's glass shows a little through the sky; the opaque themes do not
    let opaque = clamp(max(max(sketch, plastic), neon), 0.0, 1.0);
    let alpha = mix(0.9, 1.0, opaque);
    return vec4<f32>(clamp(col, vec3<f32>(0.0), vec3<f32>(1.0)), alpha);
}
