// The bar as disturbed liquid: a wave packet leaves the player controls on every
// beat and crosses the whole bar, bending everything the group holds (the glass,
// the text, the controls) as it goes. It never reads `time`, so it costs nothing
// while nothing plays: the scene's own springs are the clock.
//
// s.a.x how hard the bass is right now (0..1) · s.a.y how far the last beat has
//       travelled (0 just born, 1 gone) · s.a.z where the packet starts, as a
//       fraction of the box's width
// s.b.x how far it bends things, in px, at most · s.b.y how far the front goes
// s.b.z the Retro's pixelation: the side of a square, in px, that what the screen's opening holds is seen through (1.5 or less: none)
// s.a.w the strip's width and s.b.w the frame's thickness: where the opening starts

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
    var q = vec2<f32>(p.x + dx, p.y + dy);
    // A ripple that is always there once the shader runs (the scene runs it for the frame, `fr_wv`): the glass near each screen edge slides about 5 px at right angles to that edge,
    // by a slow wave that travels along it (round the screen: right along the bottom, up the right, left along the top, down the left), so the frame's inner edge and its notches undulate.
    // It weighs 1 at the edge and fades over about 40 px, so what is further in (the bar's own text and controls, away from the edge) hardly moves.
    let wt = exp(-p.y / 40.0);
    let wb = exp(-(s.size.y - p.y) / 40.0);
    let wl = exp(-p.x / 40.0);
    let wr = exp(-(s.size.x - p.x) / 40.0);
    let ay = 5.0 * (wt + wb) * (0.65 * sin(p.x * 0.0125 - s.time * 2.0) + 0.35 * sin(p.x * 0.0053 + s.time * 1.2 + 1.7));
    let ax = 5.0 * (wl + wr) * (0.65 * sin(p.y * 0.0125 - s.time * 2.0 + 2.0) + 0.35 * sin(p.y * 0.0053 + s.time * 1.2 + 4.1));
    q = q + vec2<f32>(ax, ay);
    // The Retro's pixelation: only inside the screen's opening, and a square's width away from its edge, so the frame itself stays still while a drawer
    // turns into squares (the group's box is the whole surface then: bar_glass.plm puts a barely visible box over it).
    let k = s.b.z;
    if (k > 1.5) {
        let inner = p.x > s.a.w + k && p.x < s.size.x - s.b.w - k && p.y > s.b.w + k && p.y < s.size.y - s.b.w - k;
        if (inner) {
            q = (floor(q / k) + vec2<f32>(0.5, 0.5)) * k;
        }
    }
    return inside(s, q);
}
