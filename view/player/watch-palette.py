# Waits, asleep, until the file named changes, and exits (0): the video player's watch on the shell's palette.plm (scripts/vitreus-player.lua starts it
# again after each change). One process doing nothing but waiting on inotify, and gone with mpv however mpv ends. It watches the file's folder,
# so a file written anew and moved into place (an atomic save) counts as well as one written in place. Exits 1 if it cannot watch.
import ctypes
import os
import struct
import sys

IN_MODIFY, IN_CLOSE_WRITE, IN_MOVED_TO, IN_CREATE = 0x2, 0x8, 0x80, 0x100
IN_CLOEXEC = 0o2000000

path = os.path.abspath(sys.argv[1])
folder, name = os.path.split(path)
libc = ctypes.CDLL(None, use_errno=True)
# ended with the player even when it is killed outright (no time to tidy): the kernel sends this one a SIGTERM when its parent goes
PR_SET_PDEATHSIG, SIGTERM = 1, 15
libc.prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0)
if os.getppid() == 1:
    sys.exit(1)                     # (the player went before that was set)
fd = libc.inotify_init1(IN_CLOEXEC)
if fd < 0 or libc.inotify_add_watch(fd, folder.encode(), IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_MODIFY) < 0:
    sys.exit(1)
while True:
    buf = os.read(fd, 65536)
    i = 0
    while i + 16 <= len(buf):
        _, _, _, size = struct.unpack_from("iIII", buf, i)
        got = buf[i + 16:i + 16 + size].split(b"\0", 1)[0].decode(errors="replace")
        i += 16 + size
        if got == name:
            sys.exit(0)
