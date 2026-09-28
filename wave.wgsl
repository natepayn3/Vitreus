// The bar as disturbed liquid: a wave packet leaves the player controls on every
// beat and crosses the whole bar, bending everything the group holds (the glass,
// the text, the controls) as it goes. It never reads `time`, so it costs nothing
// while nothing plays: the scene's own springs are the clock.
//
// s.a.x how hard the bass is right now (0..1) · s.a.y how far the last beat has
//       travelled (0 just born, 1 gone) · s.a.z where the packet starts, as a
//       fraction of the box's width
// s.b.x how far it bends things, in px, at most · s.b.y how far the front goes

fn shade(s: Shader) -> vec4<f32> {
    let pulse = s.a.x;
    let ring = s.a.y;
    let src = s.a.z * s.size.x;
    let amp = s.b.x;
    let reach = s.b.y;
    let p = s.pos;

    // The front of the beat: a few crests inside a soft envelope, moving outward
    // and dying as it goes.
    let d = abs(p.x - src);
    let ahead = d - ring * reach;
    let env = exp(-pow(ahead / 34.0, 2.0)) * (1.0 - ring);
    let crest = sin(ahead * 0.2) * env;
    let side = sign(p.x - src);

    // While the bass is hitting, the whole surface trembles a little, in phase
    // with the front: the ring value is the clock here.
    let tremble = sin(p.x * 0.05 - ring * 16.0) * 0.6 + sin(p.x * 0.13 + ring * 23.0) * 0.3;

    let dy = amp * (crest + pulse * 0.35 * tremble);
    let dx = amp * 0.4 * crest * side;
    return inside(s, vec2<f32>(p.x + dx, p.y + dy));
}
