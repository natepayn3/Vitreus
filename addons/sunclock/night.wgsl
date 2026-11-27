// The night side of the Sun Clock's map, drawn over the land: the box is the whole map, equirectangular (x is longitude -180..180 from the left,
// y latitude 90..-90 from the top). For each point the sun's height above the horizon is worked out from where the sun is overhead (the subsolar
// point); where it is below, the map is darkened and shaded with pencil strokes (darker through twilight, to full night at 12° below), and a thin
// line in the accent marks the edge of day.
//
// values: sun latitude, sun longitude (degrees), how dark night is (0..1), the pencil's frame · the hatch spacing (px), the line's width (px), -, -
// colors: night's colour, the line's colour

fn sc_rad(d: f32) -> f32 {
    return d * 0.017453292519943295;
}

fn shade(s: Shader) -> vec4<f32> {
    let lon = sc_rad(s.uv.x * 360.0 - 180.0);
    let lat = sc_rad(90.0 - s.uv.y * 180.0);
    let slat = sc_rad(s.a.x);
    let slon = sc_rad(s.a.y);
    let c = sin(lat) * sin(slat) + cos(lat) * cos(slat) * cos(lon - slon);
    let elev = asin(clamp(c, -1.0, 1.0)) * 57.29577951308232;     // the sun's height here, in degrees

    // 0 in daylight, rising through the twilights to 1 at 12° below the horizon.
    let dark = smoothstep(0.8, -12.0, elev);

    // The pencil: diagonal strokes, a hair crooked, moving with the frame (`fr`, 0 at rest), denser as night deepens.
    let fr = s.a.w;
    let sp = max(s.b.x, 2.0);
    let wob = sin(s.pos.y * 0.21 + fr * 1.7) * 0.6 + sin(s.pos.x * 0.07 + fr * 2.3) * 0.4;
    let d = fract((s.pos.x + s.pos.y * 0.8 + wob) / sp);
    let hatch = 1.0 - smoothstep(0.0, 0.32, abs(d - 0.5) * 2.0 - 0.36);
    let pencil = hatch * smoothstep(0.15, 0.9, dark);

    // The edge of day: the line where the sun sits on the horizon, about `b.y` pixels wide whatever the map's size.
    let px = s.size.y / 180.0;                                      // pixels per degree, down the map
    let line = 1.0 - smoothstep(0.0, max(s.b.y, 0.5) / px, abs(elev));

    let na = s.a.z * (0.62 * dark + 0.28 * pencil);
    let la = line * s.color2.a * 0.85;
    let a = na + la * (1.0 - na);
    if (a < 0.002) {
        return vec4<f32>(0.0);
    }
    let rgb = (s.color.rgb * na * (1.0 - la) + s.color2.rgb * la) / max(na * (1.0 - la) + la, 0.0001);
    return vec4<f32>(rgb, a);
}
