// A dashboard tile and the water, as one group's shader over everything the tile holds (its glass, a veil of water, its contents).
//
// While it is still under the surface it is seen through the water: each point takes what is a little way off, along two slow swells
// that cross each other, so the tile wavers the way something just under a calm surface does; it is tinted towards the water
// and a little flattened. As it comes up that goes to nothing.
//
// As it breaks the surface, ripples run round its rim, as the island bar's do along its edges: a crest leaves the middle of each side
// both ways and the eight meet at the corners, fading as they go. Where a crest is, the edge stands out: each point near the rim takes
// what is a little further in, and less of it the deeper it is, so the rim bulges, with a glint of light on the crest. A smaller crest
// follows each one. They run again, quicker, when it sinks.
//
// One of these runs over each tile of the dashboard. The group's box is the tile with the same margin all round (an all but invisible box
// in dashboard.plm), so the bulge has room.
//
// s.a.x how far under it still is: 1 just under the surface, 0 out of it
// s.a.y, s.a.z, s.a.w the water's colour (a group's shader is given numbers, not colours)
// s.b.x how far the crests have run (0 at the middle of each side, 1 met at the corners) · s.b.y how tall they are, in px
// s.b.z the tile's half width, in px (its half height is the box's less the same margin)

fn ripple(p: vec2<f32>, hw: f32, hh: f32, run: f32, h: f32) -> vec3<f32> {
    // Which side the point is nearest, where along the rim that is (clockwise from the top left corner), and the way out there.
    let ox = hw - abs(p.x);
    let oy = hh - abs(p.y);
    let per = 4.0 * (hw + hh);
    var along = 0.0;
    var out = vec2<f32>(0.0, -1.0);
    var depth = oy;
    if (oy < ox) {
        if (p.y < 0.0) { along = p.x + hw; out = vec2<f32>(0.0, -1.0); } else { along = 2.0 * hw + 2.0 * hh + (hw - p.x); out = vec2<f32>(0.0, 1.0); }
        depth = oy;
    } else {
        if (p.x > 0.0) { along = 2.0 * hw + (p.y + hh); out = vec2<f32>(1.0, 0.0); } else { along = 4.0 * hw + 2.0 * hh + (hh - p.y); out = vec2<f32>(-1.0, 0.0); }
        depth = ox;
    }
    // The four sources (the middle of each side), each sending a crest both ways: run 1 is a corner.
    let mids = vec4<f32>(hw, 2.0 * hw + hh, 3.0 * hw + 2.0 * hh, 4.0 * hw + 3.0 * hh);
    let wid = 46.0 + 30.0 * run;
    var crest = 0.0;
    for (var i = 0; i < 4; i = i + 1) {
        let m = mids[i];
        let side = select(hh, hw, i == 0 || i == 2);   // half the length of that side: how far its crests go to reach a corner
        let travel = run * side;
        for (var dir = -1.0; dir <= 1.0; dir = dir + 2.0) {
            var d = along - (m + dir * travel);
            d = d - per * round(d / per);                // round the rim, not across the gap at the start
            crest = crest + exp(-(d / wid) * (d / wid));
            // A smaller one following it, so it reads as a wave and not a bump.
            let e = (d + dir * wid * 1.9) / (wid * 0.8);
            crest = crest + 0.55 * exp(-e * e) * step(0.0, travel - wid);
        }
    }
    let fade = (1.0 - run) * smoothstep(0.0, 0.08, run);
    // Near a corner the way out turns, and a bulge there would tug the corner out of shape: the crests calm as they get there.
    let corner = smoothstep(30.0, 110.0, max(ox, oy));
    let reach = clamp(1.0 - depth / 84.0, 0.0, 1.0) * corner;
    let bulge = h * min(crest, 1.3) * fade * reach;
    return vec3<f32>(out * bulge, min(crest, 1.0) * fade * reach);
}

fn shade(s: Shader) -> vec4<f32> {
    let u = s.a.x;
    let h = s.b.y;
    let cen = s.size * 0.5;
    let p = s.pos;
    if (u < 0.002 && h < 0.01) {
        return inside(s, p);
    }
    let t = s.time;
    // The tile: centred in the box, which is the tile with the same margin all round.
    let hw = s.b.z;
    let hh = cen.y - (cen.x - hw);

    // The ripples round its rim.
    var at = p;
    var glint = 0.0;
    if (h >= 0.01) {
        let r = ripple(p - cen, hw, hh, s.b.x, h);
        at = at - r.xy;
        glint = r.z * 0.17;
    }

    // Under the water: two long swells at an angle to each other, moving slowly, long enough that the tile bends rather than shakes.
    let a = sin(p.y * 0.016 + p.x * 0.004 + t * 1.25) + 0.55 * sin(p.x * 0.011 - p.y * 0.007 - t * 0.9);
    let b = cos(p.x * 0.013 - p.y * 0.005 + t * 1.05) + 0.5 * sin(p.y * 0.009 + p.x * 0.006 + t * 0.7);
    let reach = 9.0 * u * u;
    let c = inside(s, at + vec2<f32>(a, b) * reach);
    // Water between the eye and the tile: its colour over it, the contrast taken down, more so the deeper.
    let grey = dot(c.rgb, vec3<f32>(0.299, 0.587, 0.114));
    var rgb = mix(c.rgb, vec3<f32>(grey), 0.25 * u);
    rgb = mix(rgb, vec3<f32>(s.a.y, s.a.z, s.a.w), 0.32 * u);
    let light = glint;
    rgb = rgb + vec3<f32>(light, light * 1.05, light * 1.1) * c.a;
    return vec4<f32>(rgb, c.a);
}
