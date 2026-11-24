// vitreus-watch: the shell's watcher. One small program that stays running, looks at the things the shell used to ask about on a timer
// (a `socat` twice a second for the workspaces, a `cat` every two seconds for the cameras), and writes a line only when one of them
// CHANGES. Started from the shell (a program it starts costs the shell about 30 ms; this one is started once), nothing but Rust's own
// library: the installer builds it with `rustc -O`, and without it the shell asks on its timers as before.
//
// What to watch is read from its input, a line each, until the input ends:
//
//   sock NAME MS CONNS PATH    a scene's socket (it answers one line per line it is sent), asked every MS milliseconds
//   ask WHAT                   a question for the last `sock`, e.g. `ask get win.shown.0`
//   cam NAME MS                the cameras' power state (/sys/class/video4linux), read every MS milliseconds
//   file NAME MS PATH          a small text file, read every MS milliseconds
//   keep START                 for the last `file`: only its lines that start so are looked at (several `keep`s: any of them)
//   tree NAME MS PATH          a folder and the folders in it: whether a file in them came, went or was written
//
// A PATH may start with `~/` (the home folder), `~cache/` ($XDG_CACHE_HOME, or ~/.cache) or `~wm/` (where pleamar-wm keeps its sockets
// and its `desktop` file for this display: $XDG_RUNTIME_DIR/pleamar-$WAYLAND_DISPLAY).
//
// What it writes, fields apart by tabs:
//
//   NAME <answer> <answer> …   a sock: every answer, in the order asked, when any of them is not what it was
//   NAME -                     a sock: nobody answers any more (written once; the answers come again when somebody does)
//   NAME <cameras> <awake>     a cam: how many there are, and how many are not suspended
//   NAME <line> <line> …       a file: the lines kept, when they are not what they were (none at all while it cannot be read)
//   NAME <files> <stamp>       a tree: how many files, and a number that is another one after any change
//
// A scene answers ONE question per frame on each connection, so forty questions down one connection take forty frames (a quarter of a
// second, during which the window manager cannot rest). CONNS connections, kept open, share them out: with 21 it is two frames.
// It ends when the shell that started it does (its parent changes), or when nobody reads what it writes.

use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::parent_id;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::{fs, process, thread};

type Out = Arc<Mutex<io::Stdout>>;

fn say(out: &Out, line: &str) {
    let mut o = out.lock().unwrap();
    if writeln!(o, "{line}").and_then(|_| o.flush()).is_err() {
        process::exit(0);
    }
}

struct Sock {
    name: String,
    ms: u64,
    conns: usize,
    path: String,
    asks: Vec<String>,
}

// One round: every connection is sent its share, then each is read. Any failure drops them all, to be opened again next time.
fn round(s: &Sock, open: &mut Vec<BufReader<UnixStream>>, answers: &mut [String]) -> io::Result<()> {
    let n = s.conns.clamp(1, s.asks.len().max(1));
    if open.is_empty() {
        for _ in 0..n {
            let c = UnixStream::connect(&s.path)?;
            c.set_read_timeout(Some(Duration::from_secs(2)))?;
            c.set_write_timeout(Some(Duration::from_secs(2)))?;
            open.push(BufReader::new(c));
        }
    }
    for (k, c) in open.iter_mut().enumerate() {
        let mut text = String::new();
        for q in s.asks.iter().skip(k).step_by(n) {
            text.push_str(q);
            text.push('\n');
        }
        c.get_mut().write_all(text.as_bytes())?;
    }
    for (k, c) in open.iter_mut().enumerate() {
        for i in (k..s.asks.len()).step_by(n) {
            let mut line = String::new();
            if c.read_line(&mut line)? == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            answers[i] = line.trim_end().replace('\t', " ");
        }
    }
    Ok(())
}

fn watch_sock(s: Sock, out: Out) {
    let mut open: Vec<BufReader<UnixStream>> = Vec::new();
    let mut answers = vec![String::new(); s.asks.len()];
    let mut last: Option<String> = None;
    loop {
        match round(&s, &mut open, &mut answers) {
            Ok(()) => {
                let line = answers.join("\t");
                if last.as_deref() != Some(line.as_str()) {
                    say(&out, &format!("{}\t{}", s.name, line));
                    last = Some(line);
                }
                thread::sleep(Duration::from_millis(s.ms));
            }
            Err(_) => {
                open.clear();
                if last.as_deref() != Some("-") {
                    say(&out, &format!("{}\t-", s.name));
                    last = Some("-".into());
                }
                thread::sleep(Duration::from_millis(s.ms.max(1000)));
            }
        }
    }
}

// The power state of each camera's USB device (the parent of its interface): all "suspended" is nobody looking.
fn watch_cam(name: String, ms: u64, out: Out) {
    let mut last = String::new();
    loop {
        let (mut all, mut awake) = (0, 0);
        if let Ok(dir) = fs::read_dir("/sys/class/video4linux") {
            for e in dir.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if !n.starts_with("video") || !n[5..].chars().all(|c| c.is_ascii_digit()) || n.len() == 5 {
                    continue;
                }
                all += 1;
                let state = fs::read_to_string(e.path().join("device/../power/runtime_status")).unwrap_or_default();
                if state.trim() != "suspended" {
                    awake += 1;
                }
            }
        }
        let line = format!("{name}\t{all}\t{awake}");
        if line != last {
            say(&out, &line);
            last = line;
        }
        thread::sleep(Duration::from_millis(ms));
    }
}

fn place(path: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    if let Some(rest) = path.strip_prefix("~cache/") {
        let cache = std::env::var("XDG_CACHE_HOME").ok().filter(|c| c.starts_with('/')).unwrap_or(format!("{home}/.cache"));
        return format!("{cache}/{rest}");
    }
    if let Some(rest) = path.strip_prefix("~wm/") {
        let run = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
        let display = std::env::var("WAYLAND_DISPLAY").unwrap_or_default();
        return if display.starts_with("pleamar") { format!("{run}/pleamar-{display}/{rest}") } else { format!("{run}/pleamar/{rest}") };
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return format!("{home}/{rest}");
    }
    path.into()
}

struct File {
    name: String,
    ms: u64,
    path: String,
    keep: Vec<String>,
}

fn watch_file(f: File, out: Out) {
    let mut last: Option<String> = None;
    loop {
        let text = fs::read_to_string(&f.path).unwrap_or_default();
        let mut line = f.name.clone();
        for l in text.lines() {
            if f.keep.is_empty() || f.keep.iter().any(|k| l.starts_with(k.as_str())) {
                line.push('\t');
                line.push_str(&l.replace('\t', " "));
            }
        }
        if last.as_deref() != Some(line.as_str()) {
            say(&out, &line);
            last = Some(line);
        }
        thread::sleep(Duration::from_millis(f.ms));
    }
}

// Every file's time of writing and size, summed: a wallpaper daemon keeps a file a monitor there (awww, in ~/.cache/awww/<version>/).
fn stamp(dir: &std::path::Path, depth: u32, files: &mut u64, sum: &mut u64) {
    use std::os::unix::fs::MetadataExt;
    let Ok(list) = fs::read_dir(dir) else { return };
    for e in list.flatten() {
        let Ok(m) = e.metadata() else { continue };
        if m.is_dir() {
            if depth > 0 {
                stamp(&e.path(), depth - 1, files, sum);
            }
        } else {
            *files += 1;
            let name: u64 = e.file_name().to_string_lossy().bytes().map(u64::from).sum();
            *sum = sum
                .wrapping_add((m.mtime() as u64).wrapping_mul(1_000_000_007))
                .wrapping_add(m.mtime_nsec() as u64)
                .wrapping_add(m.size().wrapping_mul(31))
                .wrapping_add(name.wrapping_mul(131));
        }
    }
}

fn watch_tree(name: String, ms: u64, path: String, out: Out) {
    let mut last = String::new();
    loop {
        let (mut files, mut sum) = (0, 0);
        stamp(std::path::Path::new(&path), 2, &mut files, &mut sum);
        let line = format!("{name}\t{files}\t{sum}");
        if line != last {
            say(&out, &line);
            last = line;
        }
        thread::sleep(Duration::from_millis(ms));
    }
}

fn main() {
    let born_of = parent_id();
    let out: Out = Arc::new(Mutex::new(io::stdout()));
    let mut socks: Vec<Sock> = Vec::new();
    let mut cams: Vec<(String, u64)> = Vec::new();
    let mut files: Vec<File> = Vec::new();
    let mut trees: Vec<(String, u64, String)> = Vec::new();
    for line in io::stdin().lock().lines().map_while(Result::ok) {
        let mut w = line.splitn(2, ' ');
        let (what, rest) = (w.next().unwrap_or(""), w.next().unwrap_or("").trim());
        match what {
            "sock" => {
                let p: Vec<&str> = rest.splitn(4, ' ').collect();
                if p.len() == 4 {
                    socks.push(Sock {
                        name: p[0].into(),
                        ms: p[1].parse().unwrap_or(250).max(20),
                        conns: p[2].parse().unwrap_or(1),
                        path: p[3].into(),
                        asks: Vec::new(),
                    });
                }
            }
            "ask" => {
                if let Some(s) = socks.last_mut() {
                    s.asks.push(rest.into());
                }
            }
            "cam" => {
                let p: Vec<&str> = rest.split(' ').collect();
                if p.len() == 2 {
                    cams.push((p[0].into(), p[1].parse().unwrap_or(1000).max(100)));
                }
            }
            "file" | "tree" => {
                let p: Vec<&str> = rest.splitn(3, ' ').collect();
                if p.len() == 3 {
                    let ms = p[1].parse().unwrap_or(1000).max(50);
                    if what == "file" {
                        files.push(File { name: p[0].into(), ms, path: place(p[2]), keep: Vec::new() });
                    } else {
                        trees.push((p[0].into(), ms, place(p[2])));
                    }
                }
            }
            "keep" => {
                if let Some(f) = files.last_mut() {
                    f.keep.push(rest.into());
                }
            }
            _ => {}
        }
    }
    if socks.is_empty() && cams.is_empty() && files.is_empty() && trees.is_empty() {
        eprintln!("vitreus-watch: nothing to watch (see the top of bin/vitreus-watch.rs for what its input says)");
        process::exit(2);
    }
    for s in socks {
        if !s.asks.is_empty() {
            let o = out.clone();
            thread::spawn(move || watch_sock(s, o));
        }
    }
    for (name, ms) in cams {
        let o = out.clone();
        thread::spawn(move || watch_cam(name, ms, o));
    }
    for f in files {
        let o = out.clone();
        thread::spawn(move || watch_file(f, o));
    }
    for (name, ms, path) in trees {
        let o = out.clone();
        thread::spawn(move || watch_tree(name, ms, path, o));
    }
    // The shell gone (it was killed, or it started itself again): this has nobody to tell.
    loop {
        thread::sleep(Duration::from_secs(1));
        if parent_id() != born_of {
            process::exit(0);
        }
    }
}
