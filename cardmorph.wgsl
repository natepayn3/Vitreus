// The card a Control Center tile grows into (pages/controls_drawer.plm), drawn as a drop of liquid while it is on its way: a rounded box whose edge swells and
// dents in slow lobes that run round it as it grows, and which is exactly the plain card once it is still.
// values: the card's middle (x, y, from this box's corner), its half width and half height, its corner, how much it is moving (0..1), how far it has grown
// (the lobes' phase: they move with the growth and slosh back with its bounce, and never by the clock), and what to draw: 0 its fill, 1 its hairline edge.
fn cm_box(p: vec2<f32>, half: vec2<f32>, r: f32) -> f32 {
    let q = abs(p) - half + vec2<f32>(r, r);
    return length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;
}
fn shade(s: Shader) -> vec4<f32> {
    let half = max(vec2<f32>(s.a.z, s.a.w), vec2<f32>(1.0, 1.0));
    let small = min(half.x, half.y);
    let r = min(s.b.x, small);
    let mv = clamp(s.b.y, 0.0, 1.0);
    let ph = s.b.z;
    let p = s.pos - vec2<f32>(s.a.x, s.a.y);
    var d = cm_box(p, half, r);
    // the lobes: three big ones one way and five small ones the other, so the outline never repeats itself on the way
    let ang = atan2(p.y / half.y, p.x / half.x);
    let lobes = 0.62 * sin(ang * 3.0 + ph * 7.5) + 0.38 * sin(ang * 5.0 - ph * 12.0 + 1.3);
    // and it leans the way it is pouring: fuller below while it grows, drawn in above
    let lean = 0.5 * (p.y / half.y);
    d = d - mv * small * (0.085 * lobes + 0.05 * lean);
    let px = s.scale;
    let fill = clamp(0.5 - d * px, 0.0, 1.0);
    let edge = clamp(0.5 - (abs(d + 0.5) - 0.5) * px, 0.0, 1.0);
    return vec4<f32>(s.color.rgb, mix(fill, edge, step(0.5, s.b.w)));
}
