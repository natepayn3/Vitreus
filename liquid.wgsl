// The hovered wallpaper hexagon, tilted in 3D toward the pointer and lit.
// It is a group's shader: it reads the group (the hexagon's picture and rim) with `inside`. For every point of the output it works
// out which point of the flat picture lands there once the picture is turned in space (a rotation about X and Y, then a
// perspective projection), which is what a 4x4 transform matrix does.
//
// s.a.x how hovered it is (0..1): how much of the tilt and the light there is
// s.a.y the most it tilts, in degrees, when the pointer is at the very edge
// s.a.z the light sweep's progress: 0 not started, 1 gone
// s.a.w, s.b.x where the pointer is on the hexagon, across and down, -0.5 to 0.5 (worked out by the scene: `s.pointer` is not used)

fn shade(s: Shader) -> vec4<f32> {
    let hot = s.a.x;
    let maxdeg = s.a.y;
    let sweep = s.a.z;
    let p = s.pos;
    let cen = s.size * 0.5;

    // Tilt toward the pointer: the side it is on goes back, like pressing on it.
    let rel = vec2<f32>(s.a.w, s.b.x);
    let k = 0.0174533 * maxdeg * hot;
    let ay = -rel.x * 2.0 * k;
    let ax = rel.y * 2.0 * k;
    let cx = cos(ax);
    let sx = sin(ax);
    let cy = cos(ay);
    let sy = sin(ay);
    // Rotation (X after Y), the columns that a flat picture (z = 0) uses.
    let r11 = cy;
    let r21 = sx * sy;
    let r31 = -cx * sy;
    let r12 = 0.0;
    let r22 = cx;
    let r32 = sx;

    // Perspective: the picture is seen from a distance `f`. Solving for the point (u, v) of the flat picture that lands on this pixel.
    let f = s.size.y * 1.7;
    let x = p.x - cen.x;
    let y = p.y - cen.y;
    let a11 = f * r11 - x * r31;
    let a12 = f * r12 - x * r32;
    let a21 = f * r21 - y * r31;
    let a22 = f * r22 - y * r32;
    let b1 = x * f;
    let b2 = y * f;
    let det = a11 * a22 - a12 * a21;
    let u = (b1 * a22 - a12 * b2) / det;
    let v = (a11 * b2 - b1 * a21) / det;
    let c = inside(s, cen + vec2<f32>(u, v));

    // A soft spot of light under the pointer.
    let d = length(p - (cen + rel * s.size));
    let spot = exp(-pow(d / (s.size.y * 0.3), 2.0)) * hot;

    // A band of light that crosses the hexagon on the diagonal, once, when the pointer arrives.
    let w = (p.x / s.size.x) * 0.75 + (p.y / s.size.y) * 0.25;
    let band = exp(-pow((w - (sweep * 1.7 - 0.35)) / 0.08, 2.0)) * sin(clamp(sweep, 0.0, 1.0) * 3.14159);

    let light = clamp(spot * 0.3 + band * 0.6, 0.0, 1.0);
    let rgb = mix(c.rgb, vec3<f32>(1.0, 1.0, 1.0), light * c.a);
    return vec4<f32>(rgb, c.a);
}
