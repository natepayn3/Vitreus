// The lock screen's liquid entrance: a ring-shaped disturbance leaves the centre of the wallpaper and
// settles, so it behaves like water something was dropped into. Ported from Synoptik's lockwave.frag.
//
// s.a.x entrance progress (0..1) · s.a.y peak displacement, in texture units · s.a.z rings across the
// surface. Once progress reaches 1 the envelope is exactly zero, so the resting image is pixel-exact.

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
    return inside(s, sample_uv * s.size);
}
