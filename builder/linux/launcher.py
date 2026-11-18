"""ReLink's launcher on Linux: what the Windows launcher (launcher/) and ReLink-Setup.exe do, in the AppImage
(scripts/linux/appimage.sh, builder/linux/AppRun) or from a checkout (python3 builder/linux/launcher.py).

    (no arguments)                          the window: choose your copy, Install, Play, Update
    install --game <file.nup | folder> [--out <folder>] [--language <code>] [--jobs <n>] [--no-shortcut]
    check --game <file.nup | folder>
    update [<game folder>]                  build the folder again with this ReLink (saves, settings and mods stay)
    play [<game folder>] [-- arguments]
    shortcut [<game folder>]                the application menu's entry (Steam's "Add a Non-Steam Game" lists it)
    doctor                                  what this PC has
    --update <game folder> --tag <tag>      the game's own update offer (host/hos_update.c): this ReLink updates itself to
                                            <tag> first when it is older, then builds the folder again

The build itself is nx2/make_game.py; this reads its @@ lines (its docstring) for the window's progress.
"""
import argparse
import ctypes.util
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))           # (ReLink's sources: the AppImage's usr/tools, or a checkout)
APPDIR = os.environ.get("RELINK_APPDIR", "")             # (the AppImage's root, set by AppRun; empty from a checkout)
APPIMAGE = os.environ.get("APPIMAGE", "")                # (the AppImage file itself, set by its runtime)
REPO = "pixl27/ProjectReLink"
ASSET = "ReLink-x86_64.AppImage"
HOME = os.path.expanduser("~")
DATA = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "relink")
CONFIG = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "relink", "launcher.json")
WORK = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "relink-builder")
DEFAULT_OUT = os.path.join(HOME, "Games", "ReLink")
sys.path.insert(0, os.path.join(ROOT, "nx2"))
LANGUAGES = [("en-US", "English (US)")]
try:
    from make_game import LANGUAGES   # (the build's own list: the codes language.txt takes)
except Exception:
    pass


def version():
    try:
        with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as f:
            return f.readline().strip() or "unknown"
    except OSError:
        pass
    try:
        return subprocess.run(["git", "-C", ROOT, "describe", "--tags", "--match", "v[0-9]*"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


VERSION = version()


# ---------------------------------------------------------------------------------------------------- the environment

def has_avx2():
    try:
        with open("/proc/cpuinfo") as f:
            return any(l.startswith("flags") and " avx2" in l for l in f)
    except OSError:
        return False


def build_env():
    """What nx2/make_game.py needs to find the AppImage's tools (nothing from a checkout: the system's are used)"""
    env = dict(os.environ)
    if APPDIR:
        usr = os.path.join(APPDIR, "usr")
        env["PATH"] = os.pathsep.join([os.path.join(usr, "llvm", "bin"), os.path.join(usr, "python", "bin"),
                                       env.get("RELINK_ORIG_PATH") or env.get("PATH", "")])
        env["RELINK_SYSROOT"] = os.path.join(usr, "sysroot")
        env["RELINK_FFMPEG"] = os.path.join(usr, "deps", "ffmpeg")
        env["RX_CPM"] = os.path.join(usr, "deps", "cpm")
        env["RELINK_LIBCXX"] = os.path.join(usr, "llvm", "lib", "libcxx")   # (the back end on libc++: nx2/build.py)
        env["RELINK_TOOLS"] = "1"   # (the game folder gets its own launcher, builder/linux/relink-folder)
        if has_avx2():   # (the prebuilt back end is for x86-64-v3; without AVX2 it is built here, for this CPU)
            env["RELINK_VK_PREBUILT"] = os.path.join(usr, "lib", "relink_vk.so")
        if APPIMAGE:
            env["RELINK_BUILDER_EXE"] = APPIMAGE   # (relink_version.txt's builder=: the game's update offer runs it)
    return env


def game_env():
    """The environment the game starts with: the user's own, none of the AppImage's"""
    env = dict(os.environ)
    if env.get("RELINK_ORIG_PATH"):
        env["PATH"] = env["RELINK_ORIG_PATH"]
    for k in ("RELINK_APPDIR", "RELINK_ORIG_PATH", "APPDIR", "APPIMAGE", "ARGV0", "OWD", "PYTHONHOME", "PYTHONPATH"):
        env.pop(k, None)
    return env


def make_game(args):
    return [sys.executable, "-I", "-u", "-X", "utf8", os.path.join(ROOT, "nx2", "make_game.py")] + args


def game_exe(folder):
    for p in (os.path.join(folder, "relink"), os.path.join(folder, "bin", "relink")):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def folder_version(folder):
    try:
        with open(os.path.join(folder, "relink_version.txt"), encoding="utf-8") as f:
            return next((l.split("=", 1)[1].strip() for l in f if l.startswith("version=")), None)
    except OSError:
        return None


def find_copies():
    """.nup files in Downloads, Desktop and Documents (two folders deep), newest first"""
    found = []
    for top in ("Downloads", "Desktop", "Documents"):
        base = os.path.join(HOME, top)
        for d, dirs, files in os.walk(base):
            if d[len(base):].count(os.sep) >= 2:
                dirs[:] = []
            found += [os.path.join(d, f) for f in files if f.lower().endswith(".nup")]
    return sorted(found, key=lambda p: -os.path.getmtime(p))


def load_config():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(c):
    try:
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        with open(CONFIG, "w", encoding="utf-8") as f:
            json.dump(c, f, indent=1)
    except OSError:
        pass


def shortcut(folder):
    """The application menu's entry for this game folder, with ReLink's icon"""
    exe = game_exe(folder)
    if not exe:
        raise RuntimeError("%s has no game in it" % folder)
    share = os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share")
    apps, icons = os.path.join(share, "applications"), os.path.join(share, "icons", "hicolor", "256x256", "apps")
    os.makedirs(apps, exist_ok=True)
    os.makedirs(icons, exist_ok=True)
    shutil.copyfile(os.path.join(ROOT, "assets", "relink.png"), os.path.join(icons, "relink.png"))
    path = os.path.join(apps, "relink.desktop")
    with open(path, "w", encoding="utf-8") as f:
        f.write("[Desktop Entry]\nType=Application\nName=Project ReLink\n"
                "Comment=Zelda: Ocarina of Time (Switch 2 remake), recompiled for Linux\n"
                'Exec="%s"\nPath=%s\nIcon=relink\nTerminal=false\nCategories=Game;\nStartupWMClass=relink\n' % (exe, folder))
    subprocess.run(["update-desktop-database", apps], capture_output=True) if shutil.which("update-desktop-database") else None
    return path


def play(folder, args=()):
    exe = game_exe(folder)
    if not exe:
        raise RuntimeError("There is no game in %s yet: install it first." % folder)
    return subprocess.Popen([exe] + list(args), cwd=folder, env=game_env(), start_new_session=True,
                            stdin=subprocess.DEVNULL)


def sdl_found():
    return bool(ctypes.util.find_library("SDL3") or ctypes.util.find_library("SDL2-2.0") or ctypes.util.find_library("SDL2"))


# ---------------------------------------------------------------------------------------------------- self-update

def get(url, api=False, timeout=20):
    headers = {"User-Agent": "ReLink-launcher"}
    if api:
        headers["Accept"] = "application/vnd.github+json"
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout)


def latest_release():
    """(tag, AppImage URL or None) of the latest release; None when it cannot be asked"""
    try:
        with get("https://api.github.com/repos/%s/releases/latest" % REPO, api=True) as r:
            rel = json.load(r)
        url = next((a["browser_download_url"] for a in rel.get("assets", []) if a.get("name") == ASSET), None)
        return rel["tag_name"], url
    except Exception:
        return None


def install_builder(tag, url, say=print, progress=None):
    """The release's AppImage into <data>/relink/builder/versions/<tag>, with the AppRun the game looks for there
    (host/hos_update.c installed_builder) and builder/current naming it. Returns the new AppImage's path"""
    root = os.path.join(DATA, "builder")
    dst_dir = os.path.join(root, "versions", tag)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, ASSET)
    say("Downloading ReLink %s" % tag)
    with get(url, timeout=60) as r, open(dst + ".part", "wb") as f:
        total, done = int(r.headers.get("Content-Length") or 0), 0
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
            done += len(b)
            if progress and total:
                progress(done / total)
    os.chmod(dst + ".part", 0o755)
    os.replace(dst + ".part", dst)
    with open(os.path.join(dst_dir, "AppRun"), "w") as f:
        f.write('#!/bin/sh\nexec "$(dirname "$(readlink -f "$0")")/%s" "$@"\n' % ASSET)
    os.chmod(os.path.join(dst_dir, "AppRun"), 0o755)
    with open(os.path.join(root, "current"), "w") as f:
        f.write(tag + "\n")
    for old in os.listdir(os.path.join(root, "versions")):   # (the older ones go; this one stays)
        if old != tag and os.path.realpath(os.path.join(root, "versions", old)) != os.path.dirname(os.path.realpath(APPIMAGE or "/")):
            shutil.rmtree(os.path.join(root, "versions", old), ignore_errors=True)
    return dst


# ---------------------------------------------------------------------------------------------------- the command line

def run_cli(args):
    p = subprocess.Popen(make_game(args), cwd=ROOT, env=build_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace", bufsize=1)
    try:
        for line in p.stdout:
            sys.stdout.write(line)
        return p.wait()
    except KeyboardInterrupt:
        p.send_signal(signal.SIGTERM)
        return p.wait()


def doctor():
    def line(k, v):
        print("    %-18s %s" % (k, v))
    print("ReLink %s (%s)" % (VERSION, "AppImage" if APPDIR else "from " + ROOT))
    try:
        with open("/etc/os-release") as f:
            line("system", next((l.split("=", 1)[1].strip().strip('"') for l in f if l.startswith("PRETTY_NAME=")), "?"))
    except OSError:
        pass
    try:
        with open("/proc/cpuinfo") as f:
            line("CPU", next((l.split(":", 1)[1].strip() for l in f if l.startswith("model name")), "?"))
    except OSError:
        pass
    line("AVX2", ("yes" + (" (the prebuilt renderer is used)" if APPDIR else "")) if has_avx2() else
         "no (the renderer is built for this CPU too)")
    try:
        with open("/proc/meminfo") as f:
            gb = next(int(l.split()[1]) for l in f if l.startswith("MemTotal")) / (1 << 20)
        line("memory", "%.0f GB%s" % (gb, "" if gb >= 15 else " (16 GB or more recommended: --jobs 2 if the build stops)"))
    except (OSError, StopIteration):
        pass
    os.makedirs(WORK, exist_ok=True)
    line("free in cache", "%d GB (%s; about 60 GB used while building)" % (shutil.disk_usage(WORK).free >> 30, WORK))
    line("SDL", "found" if sdl_found() else "NOT FOUND: install SDL2 or SDL3, the game's window needs it")
    line("Vulkan loader", "found" if ctypes.util.find_library("vulkan") else "NOT FOUND: install your GPU's Vulkan driver")
    if shutil.which("vulkaninfo"):
        out = subprocess.run(["vulkaninfo"], capture_output=True, text=True, errors="replace").stdout
        m = re.search(r"deviceName\s*=\s*(.+)", out)
        line("GPU", (m.group(1).strip() if m else "?") +
             (", mesh shaders" if "VK_EXT_mesh_shader" in out else ", no mesh shaders (experimental mode, slower)"))
    line("zenity", "found" if shutil.which("zenity") else "not found (the game's update question is not asked)")
    return 0


def cli(argv):
    p = argparse.ArgumentParser(prog="relink", description=__doc__.split("\n")[0])
    p.add_argument("command", choices=["install", "check", "update", "play", "shortcut", "doctor", "gui"])
    p.add_argument("folder", nargs="?")
    p.add_argument("--game")
    p.add_argument("--out")
    p.add_argument("--language")
    p.add_argument("--jobs", type=int)
    p.add_argument("--tag")
    p.add_argument("--no-shortcut", action="store_true")
    rest = argv[argv.index("--") + 1:] if "--" in argv else []   # (play: the game's own arguments)
    a = p.parse_args(argv[:argv.index("--")] if "--" in argv else argv)
    out = os.path.abspath(os.path.expanduser(a.out or a.folder or load_config().get("out") or DEFAULT_OUT))
    if a.command == "gui":
        return gui(out)
    if a.command == "doctor":
        return doctor()
    if a.command == "play":
        try:
            return play(out, rest).wait()
        except RuntimeError as e:
            sys.exit("relink: %s" % e)
    if a.command == "shortcut":
        print("menu entry: %s" % shortcut(out))
        return 0
    jobs = ["--jobs", str(a.jobs)] if a.jobs else []
    if a.command in ("install", "check"):
        if not a.game:
            sys.exit("relink: say where your copy of the game is: --game <file.nup or folder with exefs and romfs>")
        game = os.path.abspath(os.path.expanduser(a.game))
        if a.command == "check":
            return run_cli(["--check", "--game", game, "--work", WORK])
        os.makedirs(out, exist_ok=True)
        code = run_cli(["--game", game, "--out", out, "--work", WORK, "--log", os.path.join(out, "relink_build_log.txt")] +
                       (["--language", a.language] if a.language else []) + jobs)
    else:
        code = run_cli(["--update", out, "--work", WORK, "--log", os.path.join(out, "relink_build_log.txt")] + jobs)
    if code == 0:
        c = load_config()
        c["out"] = out
        save_config(c)
        if not a.no_shortcut:
            print("menu entry: %s" % shortcut(out))
        print("Play with: %s" % game_exe(out))
    return code


def from_game(argv):
    """--update <folder> --tag <tag>: the game closed itself to be updated. Newer ReLink first, then the folder"""
    p = argparse.ArgumentParser()
    p.add_argument("--update", required=True)
    p.add_argument("--tag")
    a = p.parse_args(argv)
    folder = os.path.abspath(a.update)
    if a.tag and a.tag != VERSION and APPDIR:
        found = latest_release()
        if found and found[1]:
            try:
                new = install_builder(found[0], found[1])
                os.execv(new, [new, "--update", folder, "--tag", found[0]])
            except OSError as e:
                print("relink: the new ReLink could not be downloaded (%s): building with this one" % e, file=sys.stderr)
    if has_display():
        return gui(folder, auto="update")
    return cli(["update", folder])


# ---------------------------------------------------------------------------------------------------- the window

def has_display():
    return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def pick(kind, start):
    """A file or folder chooser: the desktop's own (kdialog on KDE, zenity on GNOME) when there is one, else Tk's"""
    start = start if start and os.path.exists(start) else HOME
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
    tools = [("kdialog", ["--getopenfilename", start, "Nintendo package (*.nup)|*.nup"] if kind == "file" else
              ["--getexistingdirectory", start]),
             ("zenity", ["--file-selection", "--filename=" + start + "/"] + (["--file-filter=*.nup"] if kind == "file" else
                                                                             ["--directory"]))]
    if "KDE" not in desktop:
        tools.reverse()
    for tool, args in tools:
        if shutil.which(tool):
            r = subprocess.run([tool] + args, capture_output=True, text=True, env=game_env())
            return r.stdout.strip() if r.returncode == 0 else ""
    from tkinter import filedialog
    return (filedialog.askopenfilename(initialdir=start, filetypes=[("Nintendo package", "*.nup"), ("All files", "*")])
            if kind == "file" else filedialog.askdirectory(initialdir=start)) or ""


def gui(out, auto=None):
    import tkinter as tk
    from tkinter import messagebox, ttk

    conf = load_config()
    root = tk.Tk(className="relink")
    root.title("Project ReLink")
    root.minsize(620, 420)
    try:
        icon = tk.PhotoImage(file=os.path.join(ROOT, "assets", "relink.png"))
        root.iconphoto(True, icon)
        logo = icon.subsample(max(1, icon.width() // 72))
    except tk.TclError:
        logo = None
    style = ttk.Style(root)
    if "clam" in style.theme_names():
        style.theme_use("clam")
    style.configure("Big.TButton", padding=(18, 8))
    pad = {"padx": 12, "pady": 4}

    game = tk.StringVar(value=conf.get("game") or next(iter(find_copies()), ""))
    folder = tk.StringVar(value=out)
    langs = ["%s  %s" % l for l in LANGUAGES]
    lang = tk.StringVar(value=next((x for x in langs if x.split()[0] == conf.get("language")), langs[0]))
    menu_entry = tk.BooleanVar(value=conf.get("menu_entry", True))
    status, eta, check_text = tk.StringVar(value=""), tk.StringVar(value=""), tk.StringVar(value="")
    details_on = tk.BooleanVar(value=False)
    state = {"proc": None, "stage": "", "eta_at": None}
    lines = queue.Queue()

    head = ttk.Frame(root)
    head.pack(fill="x", padx=12, pady=(12, 4))
    if logo:
        ttk.Label(head, image=logo).pack(side="left", padx=(0, 10))
    from tkinter import font as tkfont
    title_font = tkfont.nametofont("TkDefaultFont").copy()
    title_font.configure(size=max(14, int(title_font.cget("size") or 10) + 6), weight="bold")
    ttk.Label(head, text="Project ReLink", font=title_font).pack(anchor="w")
    ttk.Label(head, text="Ocarina of Time (Switch 2 remake), built for Linux from your own copy.  Version %s" % VERSION
              ).pack(anchor="w")

    box = ttk.LabelFrame(root, text="Your copy of the game (.nup, or a folder with exefs and romfs)")
    box.pack(fill="x", **pad)
    ttk.Entry(box, textvariable=game).pack(side="left", fill="x", expand=True, padx=6, pady=6)
    ttk.Button(box, text="File…", command=lambda: game.set(pick("file", os.path.dirname(game.get())) or game.get())
               ).pack(side="left", padx=(0, 4))
    ttk.Button(box, text="Folder…", command=lambda: game.set(pick("dir", game.get()) or game.get())).pack(side="left", padx=(0, 6))
    ttk.Label(root, textvariable=check_text).pack(anchor="w", padx=16)

    box2 = ttk.LabelFrame(root, text="Game folder")
    box2.pack(fill="x", **pad)
    ttk.Entry(box2, textvariable=folder).pack(side="left", fill="x", expand=True, padx=6, pady=6)
    ttk.Button(box2, text="Choose…", command=lambda: folder.set(pick("dir", folder.get()) or folder.get())
               ).pack(side="left", padx=(0, 6))

    opts = ttk.Frame(root)
    opts.pack(fill="x", **pad)
    ttk.Label(opts, text="Language").pack(side="left")
    ttk.Combobox(opts, textvariable=lang, values=langs, state="readonly", width=28).pack(side="left", padx=6)
    ttk.Checkbutton(opts, text="Add to the application menu (and Steam's non-Steam list)", variable=menu_entry
                    ).pack(side="left", padx=12)

    buttons = ttk.Frame(root)
    buttons.pack(fill="x", **pad)
    b_install = ttk.Button(buttons, text="Install", style="Big.TButton")
    b_play = ttk.Button(buttons, text="Play", style="Big.TButton")
    b_update = ttk.Button(buttons, text="Update")
    b_open = ttk.Button(buttons, text="Open folder")
    b_cancel = ttk.Button(buttons, text="Cancel")
    for b in (b_install, b_play, b_update, b_open):
        b.pack(side="left", padx=(0, 8))

    prog = ttk.Progressbar(root, maximum=1.0)
    prog.pack(fill="x", padx=12, pady=(8, 2))
    row = ttk.Frame(root)
    row.pack(fill="x", padx=12)
    ttk.Label(row, textvariable=status).pack(side="left")
    ttk.Label(row, textvariable=eta).pack(side="right")
    ttk.Checkbutton(root, text="Show details", variable=details_on,
                    command=lambda: text_frame.pack(fill="both", expand=True, padx=12, pady=(4, 12)) if details_on.get()
                    else text_frame.pack_forget()).pack(anchor="w", padx=12, pady=(6, 0))
    text_frame = ttk.Frame(root)
    text = tk.Text(text_frame, height=12, wrap="none", font=("TkFixedFont", 9))
    sb = ttk.Scrollbar(text_frame, command=text.yview)
    text.configure(yscrollcommand=sb.set)
    sb.pack(side="right", fill="y")
    text.pack(side="left", fill="both", expand=True)

    def refresh():
        busy = state["proc"] is not None
        f = folder.get()
        have = game_exe(f) is not None
        b_install.state(["disabled"] if busy or not game.get() else ["!disabled"])
        b_play.state(["!disabled"] if have and not busy else ["disabled"])
        b_update.state(["!disabled"] if os.path.isdir(os.path.join(f, ".relink_exefs")) and not busy else ["disabled"])
        b_open.state(["!disabled"] if os.path.isdir(f) else ["disabled"])
        if busy:
            b_cancel.pack(side="right")
        else:
            b_cancel.pack_forget()
        if not busy and have and not status.get():
            v = folder_version(f)
            status.set("The game is installed%s." % (" (ReLink %s)" % v if v else "") +
                       ("  Update builds it again with %s." % VERSION if v and v != VERSION else ""))

    def log(line):
        text.insert("end", line)
        if int(text.index("end-1c").split(".")[0]) > 4000:
            text.delete("1.0", "1000.0")
        text.see("end")

    def start(args, what, on_done=None):
        save()
        prog.configure(value=0)
        status.set(what)
        eta.set("")
        text.delete("1.0", "end")
        result = {"error": None, "check": None}

        def reader(p):
            for line in p.stdout:
                lines.put(line)
            lines.put(None)

        try:
            p = subprocess.Popen(make_game(args), cwd=ROOT, env=build_env(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, encoding="utf-8", errors="replace", bufsize=1, start_new_session=True)
        except OSError as e:
            messagebox.showerror("ReLink", "The builder could not start: %s" % e)
            return
        state["proc"], state["done"], state["result"] = p, on_done, result
        threading.Thread(target=reader, args=(p,), daemon=True).start()
        refresh()

    def pump():
        try:
            while True:
                line = lines.get_nowait()
                if line is None:
                    finish()
                    break
                log(line)
                handle(line.rstrip("\n"))
        except queue.Empty:
            pass
        if state["eta_at"]:
            left = max(0, state["eta_at"] - time.time())
            eta.set("about %d min left" % max(1, round(left / 60)) if left > 0 else "")
        root.after(100, pump)

    def handle(line):
        if not line.startswith("@@"):
            return
        w = line[2:].split(" ", 2)
        r = state.get("result") or {}
        if w[0] == "stage" and len(w) == 3:
            status.set(w[2] + "…")
        elif w[0] == "progress" and len(w) >= 2:
            try:
                prog.configure(value=float(w[1]))
            except ValueError:
                pass
        elif w[0] == "eta" and len(w) >= 2 and w[1].isdigit():
            state["eta_at"] = time.time() + int(w[1])
        elif w[0] == "error":
            r["error"] = line[len("@@error "):]
        elif w[0] == "check" and len(w) >= 2:
            r["check"] = (w[1] == "ok", w[2] if len(w) == 3 else "")

    def finish():
        p = state["proc"]
        code = p.wait()
        state["proc"], state["eta_at"] = None, None
        eta.set("")
        r = state.get("result") or {}
        done = state.get("done")
        cancelled, state["cancelled"] = state.get("cancelled"), False
        refresh()   # (the buttons as they are now, before any message box)
        if code == 0 and done:
            done(r)
        elif code != 0:
            prog.configure(value=0)
            status.set("Stopped." if cancelled else "The build stopped.")
            if not cancelled:
                details_on.set(True)
                text_frame.pack(fill="both", expand=True, padx=12, pady=(4, 12))
                messagebox.showerror("ReLink", r.get("error") or "The builder stopped (exit status %d). See the details." % code)
        refresh()

    def installed(_r):
        prog.configure(value=1)
        f = folder.get()
        if menu_entry.get():
            try:
                shortcut(f)
            except (OSError, RuntimeError) as e:
                log("menu entry not added: %s\n" % e)
        status.set("The game is ready. The first start prepares its shaders once (about a quarter of an hour).")
        c = load_config()
        c["out"] = f
        save_config(c)

    def do_install():
        g, f = game.get().strip(), folder.get().strip()
        if not os.path.exists(g):
            messagebox.showerror("ReLink", "Your copy of the game was not found at:\n%s" % g)
            return
        if os.path.isdir(f) and os.listdir(f) and not os.path.isfile(os.path.join(f, "image.bin")):
            if not messagebox.askyesno("ReLink", "%s is not empty. Put the game there anyway?" % f):
                return
        os.makedirs(f, exist_ok=True)
        start(["--game", os.path.abspath(g), "--out", os.path.abspath(f), "--work", WORK, "--language", lang.get().split()[0],
               "--log", os.path.join(f, "relink_build_log.txt")], "Starting…", installed)

    def do_update():
        f = folder.get().strip()
        start(["--update", os.path.abspath(f), "--work", WORK, "--log", os.path.join(f, "relink_build_log.txt")],
              "Starting…", installed)

    def do_check(*_):
        g = game.get().strip()
        if state["proc"] is not None or not g or not os.path.exists(g):
            check_text.set("")
            return
        check_text.set("Checking your copy…")

        def run():
            r = subprocess.run(make_game(["--check", "--game", os.path.abspath(g), "--work", WORK]), cwd=ROOT,
                               env=build_env(), capture_output=True, text=True, errors="replace")
            said = next((l for l in r.stdout.splitlines()[::-1] if l.startswith(("@@check", "@@error"))), "")
            ok = said.startswith("@@check ok")
            msg = said.split(" ", 2)[-1] if said.startswith("@@check") else said[len("@@error "):]
            msg = msg.replace(os.path.abspath(g), "it")   # (the path is in the box above)
            if len(msg) > 140:
                msg = msg[:137] + "..."
            root.after(0, lambda: check_text.set(("Right version: " if ok else "Not usable: ") + (msg or "could not be checked")))

        threading.Thread(target=run, daemon=True).start()

    def do_play():
        if not sdl_found() and not messagebox.askyesno(
                "ReLink", "SDL (SDL2 or SDL3) was not found on this system: the game needs it for its window. Start anyway?"):
            return
        try:
            play(folder.get())
        except (OSError, RuntimeError) as e:
            messagebox.showerror("ReLink", str(e))
            return
        save()
        root.after(1500, root.destroy)

    def do_open():
        subprocess.Popen(["xdg-open", folder.get()], env=game_env(), start_new_session=True)

    def do_cancel():
        p = state["proc"]
        if p and messagebox.askyesno("ReLink", "Stop the build? The game folder keeps its last complete build."):
            state["cancelled"] = True
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass

    def save():
        c = load_config()
        c.update(game=game.get(), out=folder.get(), language=lang.get().split()[0], menu_entry=menu_entry.get())
        save_config(c)

    def on_close():
        if state["proc"] is not None:
            if not messagebox.askyesno("ReLink", "A build is running. Stop it and quit?"):
                return
            try:
                os.killpg(state["proc"].pid, signal.SIGTERM)
            except OSError:
                pass
        save()
        root.destroy()

    b_install.configure(command=do_install)
    b_play.configure(command=do_play)
    b_update.configure(command=do_update)
    b_open.configure(command=do_open)
    b_cancel.configure(command=do_cancel)
    root.protocol("WM_DELETE_WINDOW", on_close)
    game.trace_add("write", lambda *_: (refresh(), root.after(400, do_check)))
    folder.trace_add("write", lambda *_: (status.set(""), refresh()))
    refresh()
    do_check()
    root.after(100, pump)
    if auto == "update":
        root.after(300, do_update)
    elif APPDIR and not os.environ.get("RELINK_NO_UPDATE_CHECK"):
        def look():
            found = latest_release()
            if found and found[0] != VERSION and found[1]:
                root.after(0, lambda: status.set("ReLink %s is out (this is %s): get it from the releases page, or let the "
                                                 "game's update offer fetch it." % (found[0], VERSION)))
        threading.Thread(target=look, daemon=True).start()
    root.mainloop()
    return 0


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--update"]:
        return from_game(argv)
    if not argv:
        if not has_display():
            print(__doc__)
            return 1
        return gui(os.path.abspath(load_config().get("out") or DEFAULT_OUT))
    if argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    return cli(argv)


if __name__ == "__main__":
    sys.exit(main() or 0)
