// The soft accent glow behind the clock, as Synoptik's RadialGradient drew it: an ellipse 1.2 times the size of the
// screen, 12 % accent at the centre, 3 % at 45 % of the way out, and nothing from 80 %. It is worked out here rather
// than masked from a flat box, so it is smooth.
//
// It is drawn under the wallpaper's darkening (which multiplies everything by 0.42), so its opacity is scaled up by
// the same amount: 12 % after the darkening is 12 / 0.42 before it.

fn shade(s: Shader) -> vec4<f32> {
    let d = length((s.uv - vec2<f32>(0.5, 0.5)) * 2.0) / 1.2;
    var a = 0.0;
    if (d < 0.45) {
        a = mix(0.12, 0.03, d / 0.45);
    } else if (d < 0.8) {
        a = mix(0.03, 0.0, (d - 0.45) / 0.35);
    }
    return vec4<f32>(s.color.rgb, a / 0.42);
}
