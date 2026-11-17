#!/usr/bin/env python3
# Writes desktopcards.plm: the calendar and the reminders are two cards of one scene, and what places and drags them is the same text for each
# (a card is `cal` or `rem` in every fact), so it is written once here.
# OUT OF DATE: desktopcards.plm has been edited by hand since (the monitor names, `glide`, the holes, the permissions). Running this now would
# write an older scene over it, which its logic no longer fits. Port those edits back here before running it again.
import re, pathlib
here = pathlib.Path(__file__).parent
pal = [l for l in (here.parent / "desktopclock/desktopclock.plm").read_text().split("\n") if l.strip().startswith("fact pal_")]

def card(P, title, fw, fh, defx, defy):
    return f'''
    //  ---- {title}: {fw} x {fh} cells, by default at {defx}, {defy} ----
    fact {P}_shown = false
    fact {P}_gx = -1           // the cell of its top left corner (-1: the default one)
    fact {P}_gy = -1
    fact {P}_mon = 0           // which copy of the scene draws it (the logic keeps it)
    fact {P}_dragging = false
    fact {P}_pcx = 0           // while it is dragged: where its centre was when it was pressed, and where it is now (the desktop's own coordinates)
    fact {P}_pcy = 0
    fact {P}_dcx = 0
    fact {P}_dcy = 0
    fact {P}_zpx = 0           // and where its zone stays (a zone that moves itself would lose the drag)
    fact {P}_zpy = 0
    prop {P}_sh = 0 ~calm
    follow {P}_sh = if({P}_shown, 1, 0)
    let {P}_fw = {fw}
    let {P}_fh = {fh}
    let {P}_here = if(mi == {P}_mon, 1, 0)
    let {P}_mox = pick({P}_mon, m0x, m1x, m2x, m3x)
    let {P}_moy = pick({P}_mon, m0y, m1y, m2y, m3y)
    let {P}_gx0 = clamp(if({P}_gx < 0, {defx}, {P}_gx), 0, gnx - {P}_fw)
    let {P}_gy0 = clamp(if({P}_gy < 0, {defy}, {P}_gy), 0, gny - {P}_fh)
    prop {P}_erx = 0 ~quick
    prop {P}_ery = 0 ~quick
    follow {P}_erx = if({P}_gx < 0, {defx}, {P}_gx)
    follow {P}_ery = if({P}_gy < 0, {defy}, {P}_gy)
    let {P}_ex = clamp(mix({P}_gx0, {P}_erx, edp), 0, gnx - {P}_fw)
    let {P}_ey = clamp(mix({P}_gy0, {P}_ery, edp), 0, gny - {P}_fh)
    let {P}_x = gl + {P}_ex * gw + 3          // the card, a little inside its cells
    let {P}_y = gt + {P}_ey * gh + 3
    let {P}_w = {P}_fw * gw - 6
    let {P}_h = {P}_fh * gh - 6
    //  Dragged over to another monitor it lands there: the monitor under the card's centre shows it, and the cell is worked out against that one's grid.
    let {P}_in0 = if({P}_dcx >= m0x and {P}_dcx < m0x + m0w and {P}_dcy >= m0y and {P}_dcy < m0y + m0h, 1, 0)
    let {P}_in1 = if({P}_dcx >= m1x and {P}_dcx < m1x + m1w and {P}_dcy >= m1y and {P}_dcy < m1y + m1h, 1, 0)
    let {P}_in2 = if({P}_dcx >= m2x and {P}_dcx < m2x + m2w and {P}_dcy >= m2y and {P}_dcy < m2y + m2h, 1, 0)
    let {P}_in3 = if({P}_dcx >= m3x and {P}_dcx < m3x + m3w and {P}_dcy >= m3y and {P}_dcy < m3y + m3h, 1, 0)
    let {P}_tmon = if({P}_in0 > 0.5, 0, if({P}_in1 > 0.5, 1, if({P}_in2 > 0.5, 2, if({P}_in3 > 0.5, 3, {P}_mon))))
    let {P}_tox = pick({P}_tmon, m0x, m1x, m2x, m3x)
    let {P}_toy = pick({P}_tmon, m0y, m1y, m2y, m3y)
    let {P}_tgw = (max(pick({P}_tmon, m0w, m1w, m2w, m3w), 800) - gl - gr) / gnx
    let {P}_tgh = (max(pick({P}_tmon, m0h, m1h, m2h, m3h), 600) - gt - gb) / gny
    zone box {P}_edz {{ from: if({P}_dragging, {P}_zpx, {P}_x), if({P}_dragging, {P}_zpy, {P}_y); size: {P}_w, {P}_h; corner: 20; cursor: pointer; active: edit and {P}_shown and ({P}_here > 0.5 or {P}_dragging); label: "Move {title}" }}
    on press {P}_edz {{ {P}_pcx = {P}_mox + gl + ({P}_gx0 + {P}_fw / 2) * gw; {P}_pcy = {P}_moy + gt + ({P}_gy0 + {P}_fh / 2) * gh; {P}_dcx = {P}_pcx; {P}_dcy = {P}_pcy; {P}_zpx = {P}_x; {P}_zpy = {P}_y; {P}_dragging = true }}
    on drag {P}_edz {{ {P}_dcx = {P}_pcx + drag.dx; {P}_dcy = {P}_pcy + drag.dy }}
    on change {P}_dcx {{ {P}_mon = {P}_tmon; {P}_gx = clamp(floor(({P}_dcx - {P}_tox - gl) / {P}_tgw - {P}_fw / 2 + 0.5), 0, gnx - {P}_fw); {P}_gy = clamp(floor(({P}_dcy - {P}_toy - gt) / {P}_tgh - {P}_fh / 2 + 0.5), 0, gny - {P}_fh) }}
    on change {P}_dcy {{ {P}_mon = {P}_tmon; {P}_gx = clamp(floor(({P}_dcx - {P}_tox - gl) / {P}_tgw - {P}_fw / 2 + 0.5), 0, gnx - {P}_fw); {P}_gy = clamp(floor(({P}_dcy - {P}_toy - gt) / {P}_tgh - {P}_fh / 2 + 0.5), 0, gny - {P}_fh) }}
    on release {P}_edz {{ {P}_dragging = false; {P}_mon = {P}_tmon; {P}_gx = clamp(floor(({P}_dcx - {P}_tox - gl) / {P}_tgw - {P}_fw / 2 + 0.5), 0, gnx - {P}_fw); {P}_gy = clamp(floor(({P}_dcy - {P}_toy - gt) / {P}_tgh - {P}_fh / 2 + 0.5), 0, gny - {P}_fh) }}
'''

def glass(P):
    # the card's body: glass; flat obsidian when Vitreus has its glass off; and a plastic plate (an outline and a hard shadow, like the bar) with Retro and UwU, which are not glass themes (Cyber is glass)
    return f'''
        body {{
            color: tint
            glass: 1
            lens: false
            rim: 70%
            shine: 0, 0
            shadow: 0, 8, 22, 34%
            opacity: 85% * (1 - ob)
            show: ob < 0.996
            box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22 * (1 - 0.73 * cyk) }}
        }}
        body {{
            color: tint
            rim: 0%
            border: (2 + 1.2 * uk) * pl, deep
            shadow: 4 * pl, 5 * pl, 0, 55% + 35% * uk, mix(deep, #ff6ec7, 0.75 * uk)
            opacity: pl
            show: pl > 0.004
            box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22 * (1 - 0.73 * cyk) }}
        }}
        body {{
            color: mix(mix(tint, #000000, 0.7), ink, 0.3)
            rim: 0%
            opacity: 100% * ob * (1 - pl)
            shadow: 0, 8, 22, 45%, #000000
            show: ob * (1 - pl) > 0.004
            box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22 * (1 - 0.73 * cyk) }}
        }}
        //  The Cyber's HUD marks (the same as on its drawers, bar_glass.plm): bright corner brackets with a soft glow, 6 px outside the card, a neon hairline round it, and a little ruler of ticks under it.
        group {{
            show: cyk > 0.01
            opacity: cyk
            box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22 * (1 - 0.73 * cyk); stroke: 1.1; color: mint; opacity: 38% }}
            repeat {P}_c in 0..4 {{
                let {P}_bx = if(mod({P}_c, 2) == 0, {P}_x - 6, {P}_x + {P}_w + 6)
                let {P}_by = if({P}_c < 2, {P}_y - 6, {P}_y + {P}_h + 6)
                let {P}_sx = if(mod({P}_c, 2) == 0, -1, 1)
                let {P}_sy = if({P}_c < 2, -1, 1)
                path {{ at: {P}_bx, {P}_by; stroke: 5; color: mint; opacity: 16%; move 0, -{P}_sy * 14; line 0, 0; line -{P}_sx * 14, 0 }}
                path {{ at: {P}_bx, {P}_by; stroke: 1.7; color: minthi; move 0, -{P}_sy * 14; line 0, 0; line -{P}_sx * 14, 0 }}
            }}
            repeat {P}_k in 0..13 {{
                line {{ from: {P}_x + 22 + {P}_k * 6, {P}_y + {P}_h + 7; to: {P}_x + 22 + {P}_k * 6, {P}_y + {P}_h + 7 + if(mod({P}_k, 4) == 0, 6, 3); width: 1.1; color: mint; opacity: 70% }}
            }}
        }}'''

def frame(P, title):
    # (the reminders card already says "Reminders" in its own header: a second label over it would be the same word twice)
    label = "" if P == "rem" else f'''        text "{title}" {{ at: {P}_x + 16, {P}_y + 14; anchor: left center; size: 12; weight: 700; color: mint; family: "Space Grotesk"; shadow: 0, 1, 5, 70% }}'''
    return f'''
    group {{
        show: edp > 0.01 and {P}_here > 0.5 and {P}_sh > 0.01
        opacity: edp
        box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22; color: mint; opacity: 7% + 9% * {P}_dragging_p }}
        box {{ from: {P}_x, {P}_y; size: {P}_w, {P}_h; corner: 22; stroke: 1.6; color: mint; opacity: 55% + 45% * {P}_dragging_p }}
{label}
    }}'''

head = '''language 0.1
import "../palette-live.plm"

//  The desktop's calendar and reminders: two cards of glass on the bottom layer (above the wallpaper, under every window), in one scene since they place and drag the same way.
//  Each takes a block of the 28 x 16 grid of the desktop (inside the bar's frame and a 16 px margin) and sits at the cell its settings say; in Edit mode (`edit`, which the desktop editor sets) it is framed
//  and dragged in place, a cell at a time, even to another monitor. The editor's tiles switch them on and off (`cal_shown`, `rem_shown`).
//  Calendar: the month, with today lit; the arrows turn the month and the title brings it back. Reminders: a list to tick off, with a field to add to it.
//  Their facts and the lists are kept in ~/.local/share/pleamar/desktopcards (see desktopcards.luau).
//  THIS FILE IS WRITTEN BY gen.py: edit that and run it.

scene DesktopCards {
    surface { size: full, full; anchor: top_left; margin: 0; level: bottom; screens: each max 4; reserve: -1; keyboard: on_demand }

    permissions { services: "clock", "files", "files.write"; run: "pleamar", "hyprctl" }

'''
common = '''
    fact edit = false          // the desktop editor is open: the cards are framed and can be dragged
    fact room_t = 0            // the room the bar's frame takes round the screen (Vitreus tells it, in pixels): the grid stays out of it
    fact room_r = 0
    fact room_b = 0
    fact room_l = 0
    fact obs = false           // Vitreus has its glass off: flat obsidian
    fact look = 0              // the shell's theme (Vitreus says so): 0 Glass, 1 Retro, 2 UwU, 3 Cyber; Retro and UwU are not glass, so the cards are plastic plates there, like the bar; Cyber is glass
    prop ob = 0 ~calm
    follow ob = if(obs or look == 1 or look == 2, 1, 0)
    prop pl = 0 ~calm
    follow pl = if(look == 1 or look == 2, 1, 0)
    prop uk = 0 ~calm
    follow uk = if(look == 2, 1, 0)
    prop cyk = 0 ~calm
    follow cyk = if(look == 3, 1, 0)       // Cyber is glass, with its HUD marks on top (corner brackets, a hairline, a ruler of ticks) and squarer corners, as on the bar's drawers
    prop edp = 0 ~calm
    follow edp = if(edit, 1, 0)
    //  Where the monitors lie in the desktop (logical pixels) and how big they are, up to four, by the scene's copies (the logic asks `hyprctl`; one that is not there is 0 x 0).
'''
for k in range(4):
    for a in "xywh":
        common += f"    fact m{k}{a} = 0\n"
common += '''
    let gnx = 28           // the grid: 28 columns and 16 rows, from the bar's frame (`room_*`) plus a 16 px margin
    let gny = 16
    let gm = 16
    let gl = gm + room_l
    let gt = gm + room_t
    let gr = gm + room_r
    let gb = gm + room_b
    let mi = clamp(screen.index, 0, 3)
    let scw = pick(mi, m0w, m1w, m2w, m3w)
    let sch = pick(mi, m0h, m1h, m2h, m3h)
    let gw = (max(scw, 800) - gl - gr) / gnx
    let gh = (max(sch, 600) - gt - gb) / gny
'''

cal = '''
    //  Calendar: the month the logic worked out (`cal_title`, and 42 days from the Monday before the 1st).
    text cal_title = ""
    text cal_week = ""
    model cal_days max 42 { d: number; k: number }       // k: 0 another month, 1 a day, 2 today, 3 a weekend day
    event cal_nav ->                                    // -1 the month before, 1 the month after, 0 this month
'''
rem = '''
    //  Reminders: the list (`todos`, what the logic keeps), the line being written, and what to do with them.
    model todos max 12 { t: text; done: number }
    text rem_sub = ""
    text rem_new = ""
    event rem_toggle ->        // a row, by position
    event rem_add ->
    event rem_clear ->
'''

calui = f'''
    let cal_cw = (cal_w - 28) / 7
    let cal_top = cal_y + 96
    let cal_rh = (cal_h - 96 - 18) / 6
    zone box cal_prev {{ at: cal_x + cal_w - 76, cal_y + 32; size: 34, 34; corner: 17; cursor: pointer; active: cal_shown and edit == false and cal_here > 0.5; label: "Previous month" }}
    zone box cal_next {{ at: cal_x + cal_w - 34, cal_y + 32; size: 34, 34; corner: 17; cursor: pointer; active: cal_shown and edit == false and cal_here > 0.5; label: "Next month" }}
    zone box cal_ttl {{ at: cal_x + 110, cal_y + 32; size: 190, 34; corner: 12; cursor: pointer; active: cal_shown and edit == false and cal_here > 0.5; label: "This month" }}
    on press cal_prev {{ emit cal_nav(-1) }}
    on press cal_next {{ emit cal_nav(1) }}
    on press cal_ttl {{ emit cal_nav(0) }}
    group {{
        show: cal_sh > 0.01 and cal_here > 0.5
        opacity: cal_sh
        scale: 0.96 + 0.04 * cal_sh
        pivot: cal_x + cal_w / 2, cal_y + cal_h / 2
{glass("cal")}
        text cal_title {{ at: cal_x + 22, cal_y + 32; anchor: left center; size: 21; weight: 700; color: ink; family: "Space Grotesk" }}
        text cal_week {{ at: cal_x + 22, cal_y + 58; anchor: left center; size: 11; weight: 600; color: faint; family: "Space Grotesk" }}
        ellipse {{ at: cal_x + cal_w - 76, cal_y + 32; radius: 15; color: ink; opacity: 8% + 10% * cal_prev.hover }}
        ellipse {{ at: cal_x + cal_w - 34, cal_y + 32; radius: 15; color: ink; opacity: 8% + 10% * cal_next.hover }}
        text "‹" {{ at: cal_x + cal_w - 76, cal_y + 31; anchor: center center; size: 20; weight: 700; color: ink; family: "Space Grotesk" }}
        text "›" {{ at: cal_x + cal_w - 34, cal_y + 31; anchor: center center; size: 20; weight: 700; color: ink; family: "Space Grotesk" }}
        repeat q in 0..7 {{
            text pick(q, "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN") {{ at: cal_x + 14 + q * cal_cw + cal_cw / 2, cal_y + 84; anchor: center center; size: 10; weight: 700; color: mix(faint, mint, if(q > 4, 0.6, 0)); family: "Space Grotesk" }}
        }}
        for r in cal_days {{
            let cx = cal_x + 14 + mod(r.index, 7) * cal_cw + cal_cw / 2
            let cy = cal_top + floor(r.index / 7) * cal_rh + cal_rh / 2
            ellipse {{ at: cx, cy; radius: min(cal_cw, cal_rh) / 2 - 3; color: mint; opacity: if(r.k == 2, 1, 0) }}
            text "{{r.d}}" {{ at: cx, cy; anchor: center center; size: 15; weight: if(r.k == 2, 700, 600); color: if(r.k == 2, onmint, if(r.k == 3, mix(ink, mint, 0.55), ink)); opacity: if(r.k == 0, 30%, 100%); family: "Space Grotesk" }}
        }}
    }}
'''

remui = f'''
    let rem_rows = clamp(floor((rem_h - 150) / 34), 1, 12)
    let rem_top = rem_y + 96
    repeat i in 0..12 {{
        zone box rem_tz.$i {{ at: rem_x + 36, rem_top + i * 34 + 14; size: 30, 30; corner: 8; cursor: pointer; active: rem_shown and edit == false and rem_here > 0.5 and i < rem_rows; label: "Tick reminder" }}
        on press rem_tz.$i {{ emit rem_toggle(i) }}
    }}
    zone box rem_clr {{ at: rem_x + rem_w - 62, rem_y + 32; size: 92, 28; corner: 14; cursor: pointer; active: rem_shown and edit == false and rem_here > 0.5; label: "Clear done" }}
    on press rem_clr {{ emit rem_clear }}
    zone box rem_fz {{ at: rem_x + rem_w / 2 - 20, rem_y + rem_h - 36; size: rem_w - 90, 34; corner: 17; cursor: text; active: rem_shown and edit == false and rem_here > 0.5; label: "Write a reminder" }}
    on press rem_fz {{ focus rem_new }}
    zone box rem_add_z {{ at: rem_x + rem_w - 36, rem_y + rem_h - 36; size: 34, 34; corner: 17; cursor: pointer; active: rem_shown and edit == false and rem_here > 0.5; label: "Add reminder" }}
    on press rem_add_z {{ emit rem_add }}
    on submit rem_new {{ emit rem_add }}
    group {{
        show: rem_sh > 0.01 and rem_here > 0.5
        opacity: rem_sh
        scale: 0.96 + 0.04 * rem_sh
        pivot: rem_x + rem_w / 2, rem_y + rem_h / 2
{glass("rem")}
        text "Reminders" {{ at: rem_x + 22, rem_y + 32; anchor: left center; size: 21; weight: 700; color: ink; family: "Space Grotesk" }}
        text rem_sub {{ at: rem_x + 22, rem_y + 58; anchor: left center; size: 11; weight: 600; color: faint; family: "Space Grotesk" }}
        box {{ at: rem_x + rem_w - 62, rem_y + 32; size: 92, 28; corner: 14; color: ink; opacity: 8% + 10% * rem_clr.hover }}
        text "clear done" {{ at: rem_x + rem_w - 62, rem_y + 32; anchor: center center; size: 11; weight: 700; color: ink; family: "Space Grotesk" }}
        box {{ at: rem_x + rem_w / 2, rem_y + 76; size: rem_w - 40, 1.5; color: ink; opacity: 12% }}
        for r in todos {{
            let ry = rem_top + r.index * 34 + 14
            box {{ at: rem_x + 36, ry; size: 20, 20; corner: 6; color: mint; opacity: if(r.done > 0.5, 1, 0) }}
            box {{ at: rem_x + 36, ry; size: 20, 20; corner: 6; stroke: 1.8; color: mint; opacity: if(r.done > 0.5, 1, 60%) }}
            text "✓" {{ at: rem_x + 36, ry; anchor: center center; size: 14; weight: 800; color: onmint; opacity: if(r.done > 0.5, 1, 0); family: "Space Grotesk" }}
            text r.t {{ at: rem_x + 54, ry; anchor: left center; size: 15; weight: 600; width: rem_w - 80; lines: 1; color: if(r.done > 0.5, faint, ink); opacity: if(r.done > 0.5, 50%, 100%); family: "Space Grotesk"; show: r.index < rem_rows }}
        }}
        box {{ at: rem_x + rem_w / 2 - 20, rem_y + rem_h - 36; size: rem_w - 90, 34; corner: 17; color: ink; opacity: 9% }}
        input rem_new {{ at: rem_x + 34, rem_y + rem_h - 46; width: rem_w - 120; size: 14; weight: 500; color: ink; family: "Space Grotesk"; placeholder: "add a reminder…"; show: rem_sh > 0.5 }}
        ellipse {{ at: rem_x + rem_w - 36, rem_y + rem_h - 36; radius: 16; color: mint; opacity: 80% + 20% * rem_add_z.hover }}
        text "+" {{ at: rem_x + rem_w - 36, rem_y + rem_h - 37; anchor: center center; size: 22; weight: 700; color: onmint; family: "Space Grotesk" }}
    }}
'''

out = head + "\n".join(pal) + "\n" + common + cal + rem
out += card("cal", "Calendar", 6, 6, 0, 0) + card("rem", "Reminders", 6, 8, 22, 0)
out += calui + remui
out += frame("cal", "Calendar") + frame("rem", "Reminders")
out = out.replace("{P}", "")
out = re.sub(r"(cal|rem)_dragging_p", r"\1_dg", out)
# a spring that follows the drag (the frame lights up while it is held)
out = out.replace("    fact cal_dragging = false\n", "    fact cal_dragging = false\n    prop cal_dg = 0 ~quick\n    follow cal_dg = if(cal_dragging, 1, 0)\n")
out = out.replace("    fact rem_dragging = false\n", "    fact rem_dragging = false\n    prop rem_dg = 0 ~quick\n    follow rem_dg = if(rem_dragging, 1, 0)\n")
out += "}\n"
(here / "desktopcards.plm").write_text(out)
print("wrote", here / "desktopcards.plm")
