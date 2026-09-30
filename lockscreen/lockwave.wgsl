// The lock screen's wallpaper, in one pass: a liquid entrance (a ring-shaped disturbance leaves the centre
// and settles), then the darkening, then a dither.
//
// Once progress reaches 1 its envelope is exactly zero, so the resting
// image is pixel-exact.
//
// The darkening and the dither are here, and not a black box over the picture, on purpose. A dark gradient in 8 bits
// steps by one level and the steps show as rings. Darkening in this shader, in float, turns each step of the source
// into less than one level of the output; the noise added before the value is stored then hides what is left. Done as
// separate layers, each one stored in 8 bits, the steps were kept and the rings stayed.
//
// s.a.x entrance progress (0..1) · s.a.y peak displacement, in texture units · s.a.z rings across the surface
// s.a.w how much of the light is left after the darkening (58 % black over it: 0.42)

fn hash(p: vec2<f32>) -> f32 {
    return fract(sin(dot(p, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

fn shade(s: Shader) -> vec4<f32> {
    let aspect = s.size.x / s.size.y;
    let uv = s.uv;
    var centred = uv - vec2<f32>(0.5, 0.5);
    centred.x = centred.x * aspect;
    let dist = length(centred);

    // The front sweeps outward and stops a little past the far corner.
    let front = s.a.x * 0.85;
    // A band around the front, times a global decay so the surface is still when the entrance ends.
    let band = exp(-28.0 * (dist - front) * (dist - front));
    let decay = 1.0 - smoothstep(0.55, 1.0, s.a.x);
    let envelope = band * decay;

    let phase = (dist - front) * s.a.z * 6.28318;
    let offset = sin(phase) * s.a.y * envelope;

    var dir = vec2<f32>(0.0, 0.0);
    if (dist > 0.0001) { dir = centred / dist; }
    dir.x = dir.x / aspect;

    var sample_uv = uv + dir * offset;
    // A sample pushed outside the image would smear an edge pixel: mirror it back instead.
    sample_uv = abs(sample_uv);
    if (sample_uv.x > 1.0) { sample_uv.x = 2.0 - sample_uv.x; }
    if (sample_uv.y > 1.0) { sample_uv.y = 2.0 - sample_uv.y; }
    let c = inside(s, sample_uv * s.size);

    // Triangular noise, plus and minus one level, from two independent draws per pixel.
    let q = floor(s.pos * s.scale);
    let n = hash(q) + hash(q + vec2<f32>(17.31, 5.17)) - 1.0;
    return vec4<f32>(c.rgb * s.a.w + vec3<f32>(n / 255.0), c.a);
}
