// Vitreus: a cursor trail for Ghostty (1.2 or newer, which hands a shader the cursor).
//
// When the cursor jumps, a smear in the cursor's own colour stretches from where it was to where it is, wide at the
// cursor and thin at the tail, and the tail catches up in DURATION seconds. Small moves (typing) leave no trail.
//
// Ghostty gives: iCurrentCursor / iPreviousCursor = (x, y, width, height) in pixels, x/y the top-left corner with y counted
// from the bottom of the window; iCurrentCursorColor; iTimeCursorChange = iTime when the cursor last moved.

const float DURATION = 0.15;     // seconds for the tail to reach the cursor
const float MIN_CELLS = 2.0;     // a move shorter than this many cursor widths draws nothing
const float OPACITY = 0.85;

// distance from p to the box with this centre and half-size (negative inside)
float sdBox(vec2 p, vec2 c, vec2 h) {
    vec2 q = abs(p - c) - h;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);

    vec2 half_ = iCurrentCursor.zw * 0.5;
    vec2 now = iCurrentCursor.xy + vec2(half_.x, -half_.y);              // centres
    vec2 was = iPreviousCursor.xy + vec2(iPreviousCursor.z * 0.5, -iPreviousCursor.w * 0.5);
    vec2 path = now - was;
    if (length(path) < MIN_CELLS * max(iCurrentCursor.z, 1.0)) return;

    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float ease = 1.0 - pow(1.0 - t, 3.0);                                    // the tail starts fast and settles
    vec2 tail = mix(was, now, ease);
    vec2 seg = now - tail;
    float len2 = dot(seg, seg);
    if (len2 < 1.0) return;

    // the box swept from the tail to the cursor, narrowing toward the tail
    float k = clamp(dot(fragCoord - tail, seg) / len2, 0.0, 1.0);
    vec2 at = tail + seg * k;
    float d = sdBox(fragCoord, at, half_ * mix(0.35, 1.0, k));
    float edge = 1.0 - smoothstep(-0.75, 0.75, d);

    // leave the cursor itself to Ghostty
    float onCursor = step(sdBox(fragCoord, now, half_), 0.0);
    float a = edge * (1.0 - onCursor) * OPACITY * (1.0 - t * 0.6) * mix(0.45, 1.0, k);
    fragColor = vec4(mix(fragColor.rgb, iCurrentCursorColor.rgb, a), fragColor.a);
}
