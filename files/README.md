# Files

Vitreus's own file manager, in the shell's glass. Open it with **SUPER + E**, or type "Files" in the launcher.

* **Places** down the left: Recent, Starred, your folders, drives, network, and any folder you pin.
* **Where you are** across the top: click it, or press Ctrl+L, to type a path.
* **Tabs**, and the folder as tiles or lines (sortable, zoomable). Drag a box to choose several things.
* **Space** looks at a file; **Properties** shows its permissions and Open With.
* **Copy, cut, paste and drag**, with a question when a name is taken, progress and Cancel, and **Undo** (Ctrl+Z).
* **The Trash**, with Restore; **compress and extract**; and a **search** of names or contents.

It follows the theme (glass off, and every other theme). It uses `imagemagick`, `ffmpeg`, `poppler` and `libarchive` (`bsdtar`) for
pictures and archives.

## Making it the desktop's file manager

The installer offers it, or run `sh files/integrate.sh --set`. Then folders opened from other programs, and their «Show in folder»
(`org.freedesktop.FileManager1`), come up in Files. `sh files/integrate.sh --remove` puts the old opener back.

## Other programs' file dialogs

Run `sh files/integrate.sh --portal` and the «Open», «Upload» and «Save as» dialogs of a browser (and of any program that asks the desktop for one) come up in Files, with a strip at the
bottom: the name to save as, the kinds of file to show, Cancel, and Open or Save. Double-click a file to choose it; Escape or closing the window cancels. `--remove` puts the desktop's
own dialog back.
