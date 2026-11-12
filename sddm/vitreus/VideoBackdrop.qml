import QtQuick
import QtMultimedia

// The video behind the login screen (theme.conf's `video`): on a loop, with no sound. Main.qml loads it with a Loader, so that a greeter without
// Qt Multimedia only loses the video: the picture under it (the video's first frame) stays. It shows once its first frame is up, never as a black frame.
Item {
    id: backdrop
    property url source
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState && player.hasVideo

    MediaPlayer {
        id: player
        source: backdrop.source
        loops: MediaPlayer.Infinite
        videoOutput: out
        onSourceChanged: if (source.toString() !== "") play()     // (Main.qml gives the source once this is made)
        onErrorOccurred: (error, errorString) => console.warn("vitreus greeter: the video cannot play:", errorString)
    }
    VideoOutput {
        id: out
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: backdrop.playing ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
}
