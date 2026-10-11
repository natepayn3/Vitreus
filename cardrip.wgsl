// The picked wallpaper card's ripple, made as the island bar's is when a panel closes: two crests run out along the card's edge from the middle, and
// the edge stands out where they pass. The card is a group's picture (picture, panel, rim, words), so it is the picture itself that bulges: each pixel
// takes what is a little way along (down for the top edge, up for the foot) from where the crest is, and less and less of it the deeper it is in the card.
//
// Everything is in pixels from the middle of the group (its box is a little larger than the card, so the bulge has room):
// s.a.x how far the crests are from the middle of the edge (they go both ways)
// s.a.y how tall they are (0: nothing, the card as it is)
// s.a.z, s.a.w where the middle of the top edge and of the foot are, across
// s.b.x, s.b.y where the top edge and the foot are, down
// s.b.z how wide a crest is, s.b.w how deep into the card it reaches

fn crest(x: f32, mid: f32, travel: f32, wid: f32) -> f32 {
    let a = (x - (mid - travel)) / wid;
    let b = (x - (mid + travel)) / wid;
    return exp(-a * a) + exp(-b * b);
}

fn shade(s: Shader) -> vec4<f32> {
    let cen = s.size * 0.5;
    let p = s.pos - cen;
    let h = s.a.y;
    if (h < 0.01) {
        return inside(s, s.pos);
    }
    let gt = h * crest(p.x, s.a.z, s.a.x, s.b.z);
    let gb = h * crest(p.x, s.a.w, s.a.x, s.b.z);
    let top = s.b.x;
    let foot = s.b.y;
    let depth = max(s.b.w, 1.0);
    let dt = gt * clamp(1.0 - (p.y - top) / depth, 0.0, 1.0);
    let db = gb * clamp(1.0 - (foot - p.y) / depth, 0.0, 1.0);
    let c = inside(s, cen + vec2<f32>(p.x, p.y + dt - db));
    // a little light on the crests, as a wave catches it
    let lit = clamp((dt + db) / (h * 1.2), 0.0, 1.0) * 0.14;
    return vec4<f32>(mix(c.rgb, vec3<f32>(1.0, 1.0, 1.0), lit * c.a), c.a);
}
