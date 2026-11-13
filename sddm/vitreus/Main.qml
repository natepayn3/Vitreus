import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import Qt.labs.folderlistmodel

// Vitreus's lock screen as a login screen: the picture stays sharp, then the clock, the date, the avatar and the password bar rise in one after another.
// A typed character is a random shape (the password itself is never drawn). Sleep, restart and power off are held for a second, since none of them can be undone.
Item {
    id: root
    width: 1920
    height: 1080

    readonly property real u: Math.max(0.55, height / 1080)
    readonly property color accent: config.accent ? config.accent : "#9ed6bd"
    readonly property color ink: config.ink ? config.ink : "#f5f7f5"
    readonly property color glass: config.glass ? config.glass : "#1b2127"
    readonly property bool clock24: ownFiles["clock-24"] ? true : (ownFiles["clock-12"] ? false : config.clock24 === "true")
    readonly property string fontName: groteskBold.status === FontLoader.Ready ? groteskBold.name : "Space Grotesk"
    readonly property color barColor: Qt.rgba(Math.min(1, glass.r * 1.9 + 0.06), Math.min(1, glass.g * 2.1 + 0.08), Math.min(1, glass.b * 2.6 + 0.12), 0.58)
    readonly property color edge: Qt.rgba(ink.r, ink.g, ink.b, 0.34)

    property int stage: 0                 // 1 the picture blurs, 2 the clock, 3 the date and the avatar, 4 the bar, 5 the corners
    property string errorText: ""
    property bool leaving: false
    property date now: new Date()
    property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0
    readonly property string userName: userList.currentItem ? userList.currentItem.uname : userModel.lastUser
    readonly property string realName: userList.currentItem && userList.currentItem.real !== "" ? userList.currentItem.real : userName
    readonly property string sessionName: sessionList.currentItem ? sessionList.currentItem.sname : ""

    // The shapes a typed character can be (the lock screen's own set, 24 x 24).
    readonly property var shapePaths: [
        "M 12,2 A 10,10 0 1 0 12,22 A 10,10 0 1 0 12,2 Z",
        "M 12,2 L 22,12 L 12,22 L 2,12 Z",
        "M 5,3 L 19,3 C 20.1,3 21,3.9 21,5 L 21,19 C 21,20.1 20.1,21 19,21 L 5,21 C 3.9,21 3,20.1 3,19 L 3,5 C 3,3.9 3.9,3 5,3 Z",
        "M 12,2.5 L 22.5,20.5 L 1.5,20.5 Z",
        "M 1.5,3.5 L 22.5,3.5 L 12,21.5 Z",
        "M 12,2 L 21.5,7.5 L 21.5,16.5 L 12,22 L 2.5,16.5 L 2.5,7.5 Z",
        "M 12,2 L 22,9.2 L 18.2,21 L 5.8,21 L 2,9.2 Z",
        "M 7.5,2 L 16.5,2 L 22,7.5 L 22,16.5 L 16.5,22 L 7.5,22 L 2,16.5 L 2,7.5 Z",
        "M 12,2 Q 12,12 2,12 Q 12,12 12,22 Q 12,12 22,12 Q 12,12 12,2 Z",
        "M 12,2 L 15,8.5 L 22,9.3 L 17,14 L 18.5,21 L 12,17.5 L 5.5,21 L 7,14 L 2,9.3 L 9,8.5 Z",
        "M 9,3 L 15,3 L 15,9 L 21,9 L 21,15 L 15,15 L 15,21 L 9,21 L 9,15 L 3,15 L 3,9 L 9,9 Z",
        "M 12,21.35 L 10.55,20.03 C 5.4,15.36 2,12.28 2,8.5 C 2,5.42 4.42,3 7.5,3 C 9.24,3 10.91,3.81 12,5.09 C 13.09,3.81 14.76,3 16.5,3 C 19.58,3 22,5.42 22,8.5 C 22,12.28 18.6,15.36 13.45,20.03 Z",
        "M 12,2 A 10,10 0 0 0 22,14 A 10,10 0 1 1 12,2 Z",
        "M 12,2 L 20.5,5.5 L 20.5,11.5 C 20.5,16.8 16.9,21.2 12,22 C 7.1,21.2 3.5,16.8 3.5,11.5 L 3.5,5.5 Z"
    ]
    readonly property var shapeColors: [accent, Qt.lighter(accent, 1.35), ink, Qt.darker(accent, 1.25), "#ffd88a", "#ff9ec4"]

    // Its three weights, as their own files (a greeter runs as another user, which does not see yours; the variable file shows only its lightest)
    FontLoader { source: "fonts/SpaceGrotesk-Regular.ttf" }
    FontLoader { source: "fonts/SpaceGrotesk-Medium.ttf" }
    FontLoader { id: groteskBold; source: "fonts/SpaceGrotesk-Bold.ttf" }

    // Who and how: SDDM's models, read through a list nobody sees.
    ListView {
        id: userList
        visible: false
        width: 100; height: 100      // a list with no size makes no delegates, and currentItem stays null
        model: userModel
        currentIndex: root.userIndex
        delegate: Item { property string uname: model.name; property string real: model.realName }
    }
    ListView {
        id: sessionList
        visible: false
        width: 100; height: 100      // a list with no size makes no delegates, and currentItem stays null
        model: sessionModel
        currentIndex: root.sessionIndex
        delegate: Item { property string sname: model.name }
    }

    // What Vitreus's Settings chose (Settings > Greeter), kept in a folder of the user's (theme.conf's `shared`, which install.sh makes theirs) so that changing it needs no sudo.
    // Only the names of the files there are read, never anything to run: background.jpg (their picture, or their video's first frame), background.mp4 (their video),
    // clock-24 or clock-12 (empty files). With no background.jpg there, the theme's own picture and video are used.
    readonly property string sharedDir: config.shared ? config.shared : "/usr/local/share/vitreus-greeter"
    property var ownFiles: ({})
    property bool ownRead: false
    readonly property bool own: !!ownFiles["background.jpg"]
    readonly property string pictureSource: !ownRead ? "" : (own ? "file://" + sharedDir + "/background.jpg" : config.background)
    readonly property string videoSource: !ownRead ? "" : (own ? (ownFiles["background.mp4"] ? "file://" + sharedDir + "/background.mp4" : "") : (config.video ? Qt.resolvedUrl(config.video).toString() : ""))
    function readOwn() {
        const s = {};
        for (let i = 0; i < ownList.count; i++) s[ownList.get(i, "fileName")] = true;
        ownFiles = s;
        ownRead = true;
    }
    FolderListModel {
        id: ownList
        folder: "file://" + root.sharedDir
        showDirs: false
        onStatusChanged: if (status === FolderListModel.Ready) root.readOwn()
        onCountChanged: if (status === FolderListModel.Ready) root.readOwn()
    }
    Timer { interval: 600; running: !root.ownRead; onTriggered: root.ownRead = true }     // (no such folder: the theme's own, a moment later)

    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = new Date() }
    Timer {
        interval: 420
        running: true
        repeat: true
        onTriggered: { root.stage += 1; if (root.stage >= 5) stop() }
    }

    // ── the picture ──
    Item {
        id: picture
        anchors.fill: parent
        Image {
            anchors.fill: parent
            source: root.pictureSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }
        // A video, if theme.conf names one (VideoBackdrop.qml): over the picture, which is its first frame.
        Loader {
            anchors.fill: parent
            active: root.videoSource !== ""
            source: "VideoBackdrop.qml"
            onLoaded: item.source = Qt.binding(() => root.videoSource)
        }
        Rectangle { anchors.fill: parent; color: "#0b0e11"; opacity: root.stage >= 1 ? 0.30 : 0.10; Behavior on opacity { NumberAnimation { duration: 1600 } } }
    }
    // What the glass sees (GlassPane.qml): the picture, and a blurred copy of it for the frost, both made once and shared (the blurred one at half the size: the blur hides it).
    ShaderEffectSource { id: pictureSrc; sourceItem: picture; hideSource: false; visible: false }
    MultiEffect {
        id: pictureBlur
        width: root.width / 2; height: root.height / 2
        source: pictureSrc
        visible: false
        blurEnabled: true; blur: 1; blurMax: 48
        autoPaddingEnabled: false
    }
    ShaderEffectSource { id: frostSrc; sourceItem: pictureBlur; hideSource: true; visible: false }
    Rectangle { anchors.fill: parent; color: "black"; opacity: root.leaving ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 500 } } z: 50 }

    MouseArea { anchors.fill: parent; onClicked: pw.forceActiveFocus() }

    // A line of text whose letters grow into place one after another when `on` turns true (the lock screen does the same): each starts big, low and clear, and settles.
    // `src` is the plain Text it stands in for (kept, hidden, to size and place it); letters made later (a new minute) just appear.
    component Letters: Item {
        id: lt
        property Text src
        property bool on: false
        property int pause: 0                // before the first letter, ms
        property int stagger: 40             // between letters, ms
        property real big: 0.6               // how much bigger a letter starts, 0.6 = 1.6 times
        property real drop: 16               // how far below it starts, in px at 1080 high
        property real maxOpacity: 1
        property bool shadowed: false
        width: src.width
        height: src.height
        layer.enabled: shadowed
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#66000000"; shadowBlur: 0.9; shadowVerticalOffset: 8 }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            Repeater {
                model: lt.src.text.length
                delegate: Text {
                    id: ch
                    property real p: lt.on ? 1 : 0
                    Behavior on p {
                        SequentialAnimation {
                            PauseAnimation { duration: lt.on ? lt.pause + index * lt.stagger : 0 }
                            NumberAnimation { duration: lt.on ? 520 : 150; easing.type: Easing.OutCubic }
                        }
                    }
                    text: lt.src.text.charAt(index)
                    color: lt.src.color
                    font: lt.src.font
                    opacity: p * lt.maxOpacity
                    scale: 1 + lt.big * (1 - p)
                    transformOrigin: Item.Center
                    transform: Translate { y: lt.drop * root.u * (1 - ch.p) }
                }
            }
        }
    }

    // ── the clock and the date ──
    Item {
        id: clockBox
        width: clockText.width + 70 * root.u
        height: clockText.height
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height * 0.142 + (root.stage >= 2 ? 0 : 26 * root.u)
        opacity: root.stage >= 2 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 800; easing.type: Easing.OutBack } }
        Text {
            id: clockText
            x: 0
            text: root.clock24 ? Qt.formatTime(root.now, "HH:mm") : ((root.now.getHours() % 12 === 0 ? 12 : root.now.getHours() % 12) + ":" + Qt.formatTime(root.now, "mm"))
            color: root.ink
            visible: false
            font.family: root.fontName
            font.pixelSize: 230 * root.u
            font.weight: Font.Bold
        }
        Letters { anchors.fill: clockText; src: clockText; on: root.stage >= 2; pause: 150; stagger: 55; big: 1.1; drop: 50; maxOpacity: 0.88; shadowed: true }
        Rectangle {
            visible: !root.clock24
            x: clockText.width + 10 * root.u
            y: clockText.height * 0.34
            width: ampm.width + 22 * root.u
            height: 30 * root.u
            radius: height / 2
            color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.14)
            border.color: root.edge
            border.width: 1
            Text {
                id: ampm
                anchors.centerIn: parent
                text: root.now.getHours() < 12 ? "AM" : "PM"
                color: root.ink
                font.family: root.fontName
                font.pixelSize: 14 * root.u
                font.weight: Font.Medium
            }
        }
    }
    Text {
        id: dateText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: clockBox.bottom
        anchors.topMargin: -22 * root.u
        text: Qt.formatDate(root.now, "dddd, MMMM d, yyyy")
        color: root.ink
        visible: false
        font.family: root.fontName
        font.pixelSize: 25 * root.u
        font.weight: Font.Medium
    }
    Letters { anchors.fill: dateText; src: dateText; on: root.stage >= 3; pause: 100; stagger: 16; maxOpacity: 0.85 }

    // ── who ──
    Item {
        id: who
        width: 170 * root.u
        height: 170 * root.u
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: dateText.bottom
        anchors.topMargin: 34 * root.u
        opacity: root.stage >= 3 ? 1 : 0
        scale: root.stage >= 3 ? 1 : 0.8
        Behavior on opacity { NumberAnimation { duration: 600 } }
        Behavior on scale { NumberAnimation { duration: 700; easing.type: Easing.OutBack } }

        // The frame: an aurora blob that slowly morphs (6 s) and turns (9 s), with a darker "ghost" blob set inside it turning the other way; the disc is over the middle.
        Canvas {
            id: blob
            width: parent.width * 1.3
            height: width
            anchors.centerIn: parent
            // Drawn on the graphics card and off the main thread, and only 20 times a second: a slow morph does not need more, and the greeter has no GPU to spare.
            renderTarget: Canvas.FramebufferObject
            renderStrategy: Canvas.Threaded
            property real t: 0
            function edge(th, base, m) { return base * (1 + 0.06 * Math.sin(2 * th + m) + 0.045 * Math.sin(3 * th - m + 1.3) + 0.025 * Math.sin(5 * th + 2 * m)) }
            function trace(ctx, cx, cy, base, dir, phase) {
                var m = 2 * Math.PI * t / 6 + phase, spin = 2 * Math.PI * t / 9
                ctx.beginPath()
                for (var i = 0; i <= 64; i++) {
                    var a = i / 64 * 2 * Math.PI
                    var r = edge(a - dir * spin, base, m)
                    var x = cx + r * Math.cos(a), y = cy + r * Math.sin(a)
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                }
                ctx.closePath()
            }
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var c = width / 2, R = parent.width / 2
                var spin = 2 * Math.PI * t / 9
                var gx = Math.cos(spin + 0.8) * R * 1.15, gy = Math.sin(spin + 0.8) * R * 1.15
                var g = ctx.createLinearGradient(c - gx, c - gy, c + gx, c + gy)
                g.addColorStop(0, Qt.darker(root.accent, 1.25))
                g.addColorStop(0.5, root.accent)
                g.addColorStop(1, Qt.lighter(root.accent, 1.45))
                // The glow: a wider, fainter copy under it (a blurred shadow, redrawn each time, was what made this slow).
                trace(ctx, c, c, R * 1.2, 1, 0)
                ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                ctx.fill()
                trace(ctx, c, c, R * 1.14, 1, 0)
                ctx.fillStyle = g
                ctx.fill()
                trace(ctx, c, c, R * 1.06, -1, 2.1)
                ctx.fillStyle = Qt.rgba(0, 0, 0, 0.30)
                ctx.fill()
            }
            Timer { interval: 50; repeat: true; running: root.stage >= 3 && !root.leaving; onTriggered: { blob.t += 0.05; blob.requestPaint() } }
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: root.barColor
        }
        Item {
            id: faceMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle { anchors.fill: parent; anchors.margins: 3; radius: width / 2 }
        }
        Image {
            id: face
            anchors.fill: parent
            // your face, from the folder install.sh made for it (it is the one that changes when you change your picture); the copy in the theme is the one it was installed with
            property bool bundled: false
            source: bundled ? config.avatar : "file://" + root.sharedDir + "/avatar.png"
            onStatusChanged: if (status === Image.Error && !bundled) bundled = true
            cache: false
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
            layer.enabled: true
            layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask }
        }
        // no picture: a person, drawn
        Shape {
            visible: face.status !== Image.Ready
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: 3.6 * root.u
            ShapePath {
                strokeColor: root.ink
                strokeWidth: 1.5
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathSvg { path: "M 12,4 A 3.6,3.6 0 1 0 12,11.2 A 3.6,3.6 0 1 0 12,4 Z M 4.5,20.5 C 4.5,16.4 7.9,13.6 12,13.6 C 16.1,13.6 19.5,16.4 19.5,20.5" }
            }
        }
        MouseArea { anchors.fill: parent; enabled: userModel.count > 1; cursorShape: Qt.PointingHandCursor; onClicked: { root.userIndex = (root.userIndex + 1) % userModel.count; pw.forceActiveFocus() } }
    }
    Text {
        id: nameText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: who.bottom
        anchors.topMargin: 16 * root.u
        text: root.realName !== "" ? root.realName : qsTr("Welcome")
        color: root.ink
        visible: false
        font.family: root.fontName
        font.pixelSize: 24 * root.u
        font.weight: Font.Bold
    }
    Letters { anchors.fill: nameText; src: nameText; on: root.stage >= 3; pause: 250; stagger: 28 }
    Text {
        id: subText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: nameText.bottom
        anchors.topMargin: 2 * root.u
        text: root.errorText !== "" ? root.errorText : (root.realName !== "" ? qsTr("Welcome back") : "")
        color: root.errorText !== "" ? "#ff9ec4" : root.ink
        opacity: root.stage >= 3 ? (root.errorText !== "" ? 1 : 0.7) : 0
        Behavior on opacity { NumberAnimation { duration: 400 } }
        font.family: root.fontName
        font.pixelSize: 14 * root.u
        font.weight: Font.Medium
    }

    // ── the password bar ──
    Rectangle {
        id: bar
        width: 470 * root.u
        height: 56 * root.u
        radius: height / 2
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: subText.bottom
        anchors.topMargin: 22 * root.u
        // glass when the shader loads, and then only a veil of the colour over it; else the plain translucent fill it always had
        color: barGlass.ready ? Qt.rgba(root.barColor.r, root.barColor.g, root.barColor.b, 0.22) : root.barColor
        border.color: pw.activeFocus ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7) : root.edge
        border.width: 1.5
        opacity: root.stage >= 4 ? 1 : 0
        property real shake: 0
        transform: Translate { x: bar.shake }
        Behavior on opacity { NumberAnimation { duration: 600 } }
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#44000000"; shadowBlur: 0.7; shadowVerticalOffset: 6 }

        GlassPane {
            id: barGlass
            anchors.fill: parent
            z: -1
            radius: bar.radius
            backdrop: picture
            source: pictureSrc
            frosted: frostSrc
            bevel: 18 * root.u
            refraction: 22 * root.u
        }

        SequentialAnimation {
            id: shakeAnim
            NumberAnimation { target: bar; property: "shake"; to: -14 * root.u; duration: 60 }
            NumberAnimation { target: bar; property: "shake"; to: 12 * root.u; duration: 90 }
            NumberAnimation { target: bar; property: "shake"; to: -8 * root.u; duration: 80 }
            NumberAnimation { target: bar; property: "shake"; to: 0; duration: 80 }
        }

        // the lock
        Shape {
            x: 20 * root.u
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24
            scale: 0.9 * root.u
            ShapePath {
                strokeColor: root.ink
                strokeWidth: 1.7
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: "M 6,10.5 L 18,10.5 Q 19.5,10.5 19.5,12 L 19.5,19.5 Q 19.5,21 18,21 L 6,21 Q 4.5,21 4.5,19.5 L 4.5,12 Q 4.5,10.5 6,10.5 Z M 8,10.5 L 8,7.5 A 4,4 0 0 1 16,7.5 L 16,10.5" }
            }
        }
        Text {
            visible: pw.text.length === 0
            x: 60 * root.u
            anchors.verticalCenter: parent.verticalCenter
            text: root.leaving ? qsTr("Signing in…") : qsTr("Enter password…")
            color: root.ink
            opacity: 0.55
            font.family: root.fontName
            font.pixelSize: 17 * root.u
            font.weight: Font.Medium
        }
        // what was typed: a shape for each character
        ListModel { id: picks }
        Row {
            x: 56 * root.u
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6 * root.u
            Repeater {
                model: picks
                // Each shape is a spring, the one the Unsaid Word Rewind component uses (stiffness .18, friction .8 a frame): it comes in thin and tall with a bounce, and
                // when it is taken back it goes in about four frames while the ones after it close up. `gone` marks one on its way out.
                delegate: Item {
                    id: slot
                    property real p: 0
                    property real v: 0
                    readonly property real pp: Math.max(p, 0)
                    readonly property real target: model.gone ? 0 : 1
                    width: 24 * pp
                    height: 24
                    FrameAnimation {
                        running: Math.abs(slot.v) > 0.001 || Math.abs(slot.target - slot.p) > 0.001
                        onTriggered: {
                            var dt = Math.min(frameTime, 0.05) * 60
                            slot.v = (slot.v + (slot.target - slot.p) * 0.18 * dt) * Math.pow(0.8, dt)
                            slot.p += slot.v * dt
                            if (model.gone && slot.p <= 0) root.dropPick(model.uid)
                        }
                    }
                    Shape {
                        width: 24
                        height: 24
                        opacity: Math.min(1, slot.pp * 1.4)
                        transform: Scale {
                            origin.x: 12
                            origin.y: 12
                            xScale: 0.82 * root.u * slot.pp
                            yScale: 0.82 * root.u * (slot.pp < 1 ? 1 + (1 - slot.pp) * 0.6 : slot.pp)
                        }
                        ShapePath {
                            fillColor: root.shapeColors[model.col]
                            strokeColor: "transparent"
                            fillRule: ShapePath.OddEvenFill
                            PathSvg { path: root.shapePaths[model.kind] }
                        }
                    }
                }
            }
        }
        // A clear (Esc, or a wrong password) unsays the shapes from the end, one every 70 ms, like holding Backspace.
        Timer {
            id: rewinder
            interval: 70
            repeat: true
            onTriggered: { if (root.liveCount() > pw.text.length) root.unsayOne(); else stop() }
        }
        // go
        Rectangle {
            id: go
            width: 42 * root.u
            height: width
            radius: width / 2
            anchors.right: parent.right
            anchors.rightMargin: 7 * root.u
            anchors.verticalCenter: parent.verticalCenter
            color: pw.text.length > 0 ? root.accent : Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.14)
            Behavior on color { ColorAnimation { duration: 200 } }
            Shape {
                anchors.centerIn: parent
                width: 24
                height: 24
                scale: 0.9 * root.u
                ShapePath {
                    strokeColor: pw.text.length > 0 ? "#10161a" : root.ink
                    strokeWidth: 2
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: "M 5,12 L 19,12 M 13,6 L 19,12 L 13,18" }
                }
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tryLogin() }
        }
    }

    // The field that takes the keys: nothing of it is seen.
    TextInput {
        id: pw
        width: 1
        height: 1
        opacity: 0
        echoMode: TextInput.Password
        focus: true
        enabled: !root.leaving
        onAccepted: root.tryLogin()
        onTextChanged: {
            root.errorText = ""
            var live = root.liveCount()
            if (text.length > live) {
                rewinder.stop()
                for (var i = picks.count - 1; i >= 0; i--) if (picks.get(i).gone) picks.remove(i)     // typing again: what was on its way out is gone
                while (picks.count < text.length) picks.append({ kind: Math.floor(Math.random() * root.shapePaths.length), col: Math.floor(Math.random() * root.shapeColors.length), gone: false, uid: ++root.pickSeq })
            } else if (text.length < live) {
                if (text.length === 0 && live > 1) rewinder.start()
                else while (root.liveCount() > text.length) root.unsayOne()
            }
        }
        Keys.onEscapePressed: text = ""
    }
    property int pickSeq: 0
    function liveCount() { var n = 0; for (var i = 0; i < picks.count; i++) if (!picks.get(i).gone) n++; return n }
    function unsayOne() { for (var i = picks.count - 1; i >= 0; i--) if (!picks.get(i).gone) { picks.setProperty(i, "gone", true); return } }
    function dropPick(uid) { for (var i = 0; i < picks.count; i++) if (picks.get(i).uid === uid) { picks.remove(i); return } }
    function tryLogin() {
        if (pw.text.length === 0 || root.leaving) return
        sddm.login(root.userName, pw.text, root.sessionIndex)
    }
    Connections {
        target: sddm
        function onLoginFailed() {
            root.errorText = qsTr("Wrong password")
            pw.text = ""
            shakeAnim.restart()
            pw.forceActiveFocus()
        }
        function onLoginSucceeded() { root.leaving = true }
    }
    Component.onCompleted: pw.forceActiveFocus()

    // Settings' Test runs SDDM's test mode, which opens one window per monitor: there, only the main monitor's stays (a real login still covers every one).
    Timer {
        interval: 0
        running: typeof primaryScreen !== "undefined" && !primaryScreen && Qt.application.arguments.indexOf("--test-mode") >= 0
        onTriggered: if (root.Window.window) root.Window.window.close()
    }

    // ── the corners: the machine, and how to log in ──
    Rectangle {
        x: 34 * root.u
        y: 30 * root.u
        height: 34 * root.u
        width: hostText.width + 34 * root.u
        radius: height / 2
        color: Qt.rgba(root.glass.r, root.glass.g, root.glass.b, 0.45)
        border.color: root.edge
        opacity: root.stage >= 5 ? 1 : 0
        visible: sddm.hostName !== ""
        Behavior on opacity { NumberAnimation { duration: 600 } }
        Text { id: hostText; anchors.centerIn: parent; text: sddm.hostName; color: root.ink; opacity: 0.85; font.family: root.fontName; font.pixelSize: 14 * root.u; font.weight: Font.Medium }
    }
    Rectangle {
        id: sessionChip
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: bar.bottom
        anchors.topMargin: 20 * root.u
        height: 52 * root.u
        width: sessionLabel.width + 64 * root.u
        radius: height / 2
        color: Qt.rgba(root.glass.r, root.glass.g, root.glass.b, sessionMouse.containsMouse ? 0.7 : 0.45)
        border.color: root.edge
        opacity: root.stage >= 4 ? 1 : 0
        visible: sessionModel.count > 0 && root.sessionName !== ""
        Behavior on opacity { NumberAnimation { duration: 600 } }
        Text { id: sessionLabel; anchors.centerIn: parent; text: root.sessionName; color: root.ink; opacity: 0.9; font.family: root.fontName; font.pixelSize: 21 * root.u; font.weight: Font.Medium }
        MouseArea {
            id: sessionMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.sessionIndex = (root.sessionIndex + 1) % sessionModel.count; pw.forceActiveFocus() }
        }
    }

    // ── sleep, restart, power off: each held for a second ──
    Rectangle {
        id: power
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 40 * root.u
        height: 58 * root.u
        width: powerRow.width + 28 * root.u
        radius: height / 2
        color: Qt.rgba(root.glass.r, root.glass.g, root.glass.b, 0.5)
        border.color: root.edge
        opacity: root.stage >= 5 ? 1 : 0
        visible: powerRow.width > 0
        Behavior on opacity { NumberAnimation { duration: 600 } }
        property string holding: ""
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.top
            anchors.bottomMargin: 10 * root.u
            text: power.holding
            color: root.ink
            opacity: power.holding !== "" ? 0.8 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
            font.family: root.fontName
            font.pixelSize: 14 * root.u
            font.weight: Font.Medium
        }
        Row {
            id: powerRow
            anchors.centerIn: parent
            spacing: 14 * root.u
            Repeater {
                model: [
                    { label: qsTr("Hold to sleep"), ok: sddm.canSuspend, path: "M 12,2 A 10,10 0 0 0 22,14 A 10,10 0 1 1 12,2 Z", act: 0, fill: true },
                    { label: qsTr("Hold to restart"), ok: sddm.canReboot, path: "M 19.5,12 A 7.5,7.5 0 1 1 16,5.6 M 16.5,2.5 L 16.5,6.5 L 12.5,6.5", act: 1, fill: false },
                    { label: qsTr("Hold to power off"), ok: sddm.canPowerOff, path: "M 12,3 L 12,12 M 6.4,6.4 A 8,8 0 1 0 17.6,6.4", act: 2, fill: false }
                ]
                delegate: Item {
                    id: pb
                    visible: modelData.ok
                    width: visible ? 42 * root.u : 0
                    height: 42 * root.u
                    property real prog: 0
                    Rectangle { anchors.fill: parent; radius: width / 2; color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, pbMouse.containsMouse ? 0.2 : 0.1) }
                    Shape {
                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        scale: 0.8 * root.u
                        ShapePath {
                            strokeColor: modelData.fill ? "transparent" : root.ink
                            strokeWidth: 1.9
                            fillColor: modelData.fill ? root.ink : "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            PathSvg { path: modelData.path }
                        }
                    }
                    Shape {
                        anchors.fill: parent
                        visible: pb.prog > 0
                        ShapePath {
                            strokeColor: root.accent
                            strokeWidth: 3
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            PathAngleArc { centerX: pb.width / 2; centerY: pb.height / 2; radiusX: pb.width / 2 - 1.5; radiusY: pb.height / 2 - 1.5; startAngle: -90; sweepAngle: 360 * pb.prog }
                        }
                    }
                    NumberAnimation {
                        id: fill
                        target: pb
                        property: "prog"
                        from: 0
                        to: 1
                        duration: 1000
                        onFinished: {
                            power.holding = ""
                            pb.prog = 0
                            if (modelData.act === 0) sddm.suspend()
                            else if (modelData.act === 1) sddm.reboot()
                            else sddm.powerOff()
                        }
                    }
                    MouseArea {
                        id: pbMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: { power.holding = modelData.label; fill.start() }
                        onReleased: { fill.stop(); pb.prog = 0; power.holding = "" }
                    }
                }
            }
        }
    }
}
