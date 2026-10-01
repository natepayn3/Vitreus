// A hexagon dissolve: the picture the group holds appears through a honeycomb, each hexagon opening from its own middle until it fills
// its cell. The hexagons are the picker's (pointy-top), and they open in a wave from where the wallpaper was picked, with a little of
// chance in the order so that it is not a ring.
//
// s.a.x progress (0..1) · s.a.y the hexagon's radius, corner to middle, in pixels · s.a.z, s.a.w where the wave starts, in pixels
// s.b.x how much of the order is that wave (1) and how much is chance (0) · s.b.y how long each hexagon takes to open (0..1 of the whole)

// What `inside` gives back is the picture as the screen shows it (sRGB), and what a shader returns is taken as light and encoded again for the
// screen: unchanged, the picture came out washed, with its shadows lifted. So the picture is decoded to light here, and the screen's own
// encoding then puts it back as it was.
fn to_light(c: vec3<f32>) -> vec3<f32> {
    let v = max(c, vec3<f32>(0.0));
    return select(pow((v + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4)), v / 12.92, v <= vec3<f32>(0.04045));
}

// s.b.z is 1 where the screen encodes what a shader returns (a float surface, as on Hyprland) and 0 where it does not (an 8-bit one, as under
// pleamar-wm): there the picture is already as it should be, and decoding it would only darken it.
fn wp_decode(s: Shader, c: vec3<f32>) -> vec3<f32> {
    return select(c, to_light(c), s.b.z > 0.5);
}

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

fn shade(s: Shader) -> vec4<f32> {
    let p = s.pos;
    // Once it is over, the picture itself: no seams where hexagons meet.
    if (s.a.x >= 0.999) {
        let f = inside(s, p);
        return vec4<f32>(wp_decode(s, f.rgb), f.a);
    }

    let r = s.a.y;
    let sq3 = 1.7320508;

    // Which hexagon this point is in: axial coordinates of a pointy-top grid, rounded in cube space.
    let qf = (sq3 / 3.0 * p.x - p.y / 3.0) / r;
    let rf = (2.0 / 3.0 * p.y) / r;
    let yf = -qf - rf;
    var rx = round(qf);
    var ry = round(yf);
    var rz = round(rf);
    let dx = abs(rx - qf);
    let dy = abs(ry - yf);
    let dz = abs(rz - rf);
    if (dx > dy && dx > dz) {
        rx = -ry - rz;
    } else if (dy > dz) {
        ry = -rx - rz;
    } else {
        rz = -rx - ry;
    }
    let centre = vec2<f32>(r * sq3 * (rx + rz * 0.5), r * 1.5 * rz);

    // When this hexagon starts: part wave from the origin, part chance.
    let reach = length(s.size);
    let wave = clamp(length(centre - vec2<f32>(s.a.z, s.a.w)) / reach, 0.0, 1.0);
    let chance = hash(vec2<f32>(rx, rz));
    let lead = 1.0 - s.b.y;
    let delay = mix(chance, wave, s.b.x) * lead;
    let t = clamp((s.a.x - delay) / s.b.y, 0.0, 1.0);
    let ease = t * t * (3.0 - 2.0 * t);

    // How far from the middle this point is, in hexagons: the edge is at `a` (the hexagon's inradius) along each of three directions.
    let q = p - centre;
    let a = r * sq3 * 0.5;
    let d = max(abs(q.x), max(abs(dot(q, vec2<f32>(0.5, 0.8660254))), abs(dot(q, vec2<f32>(-0.5, 0.8660254)))));
    // It grows to a little more than its cell, so that neighbours overlap and nothing is left between them.
    let grown = a * ease * 1.05;
    // Nothing until it has a size: a hexagon of none would still be half a pixel wide in the middle of its cell.
    if (grown < 1.0) {
        return vec4<f32>(0.0, 0.0, 0.0, 0.0);
    }
    let sd = d - grown;
    let soft = 0.9 / s.scale;
    let cover = 1.0 - smoothstep(-soft, soft, sd) ;

    let c0 = inside(s, p);
    let c = vec4<f32>(wp_decode(s, c0.rgb), c0.a);
    // The edge catches the light while the hexagon is still growing.
    let rim = (1.0 - smoothstep(0.0, 5.0, -sd)) * (1.0 - ease);
    let rgb = mix(c.rgb, vec3<f32>(1.0, 1.0, 1.0), 0.28 * rim);
    return vec4<f32>(rgb, c.a * cover);
}
