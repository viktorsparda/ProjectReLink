# ReLink on Linux (Bazzite, SteamOS, Fedora and others)

ReLink builds a native Linux game from your own copy, the same way the Windows version does: the game's code is translated
and compiled on your PC, with no emulator and no Wine or Proton. The result is a folder with `bin/relink` (the game),
`relink_vk.so` (its Vulkan renderer) and the game's files, which runs directly on your system.

There is no graphical launcher on Linux yet: `linux/relink-linux.sh` does what the Windows launcher does, from a terminal,
and the game's own **Insert** / **F1** menu has every setting.

**The game version you need** is the same as on Windows (program `0400486024DEC000`, update v131072, build `e0f3ccfa`), as a
`.nup` file or as its `romfs` and `exefs` folders.

## On Bazzite (and other immutable systems)

Bazzite's base system cannot take packages, so ReLink builds inside a container with **podman**, which Bazzite already has.
Nothing is installed on your system: the container holds clang, Python and the libraries the build needs, and the finished
game runs on Bazzite itself.

1. Open **Konsole** (KDE) or **Terminal** (GNOME). In Gaming Mode, switch to Desktop Mode first.
2. Get ReLink's sources (a release tag is best, it lets the game offer updates):

   ```bash
   git clone --depth 1 --branch <latest release tag, e.g. v0.7.9.1> https://github.com/pixl27/ProjectReLink ~/ReLink-src
   ```

3. Check your copy of the game (optional, quick):

   ```bash
   ~/ReLink-src/linux/relink-linux.sh check --game ~/Downloads/<your file>.nup
   ```

4. Build the game:

   ```bash
   ~/ReLink-src/linux/relink-linux.sh install --game ~/Downloads/<your file>.nup
   ```

   The first time, it prepares the build container (5 to 10 minutes, about 2 GB). Then it builds the game into
   `~/Games/ReLink` (`--out <folder>` to choose another): 10 to 45 minutes depending on your CPU. The whole log goes to
   `relink_build_log.txt` in the game folder.

5. Play: **Project ReLink** is now in your application menu. Or from a terminal:

   ```bash
   ~/Games/ReLink/relink
   ```

The first start prepares the shaders and pipelines once (about a quarter of an hour), with a progress screen, as on Windows.

### In Steam and Gaming Mode

In Desktop Mode, open Steam, then **Games → Add a Non-Steam Game to My Library…**, tick **Project ReLink** and press
**Add Selected Programs**. It then shows in Gaming Mode's library. Leave its compatibility setting off: this is a native
Linux game, not one for Proton.

Controllers work through SDL (Bazzite's own): Xbox pads, DualSense, DualShock 4, Switch Pro and the Steam Deck's controls.
With Steam Input on, Steam presents them as an Xbox pad, which works too.

## On other distributions

The same script works anywhere. It uses podman or docker when it finds one and the system has no compiler; otherwise, or with
`--native`, it builds with the system's own tools. For a native build install:

- **Fedora**: `sudo dnf install clang lld llvm git make nasm meson ninja-build python3-pip libstdc++-static`
- **Debian, Ubuntu**: `sudo apt install clang lld llvm git make nasm meson ninja-build python3-pip`
- **Arch**: `sudo pacman -S clang lld llvm git make nasm meson ninja python-pip`

and the Python packages `capstone numpy zstandard lz4 pillow` (`pip install --user ...`, or your distribution's packages).
The first native build makes FFmpeg (only the video decoders the game needs) and fetches the Vulkan headers into
`~/.local/share/relink/deps`, once (`linux/build-deps.sh`).

Docker instead of podman: `RELINK_ENGINE=docker`. On a non-Fedora system the container is Fedora 41; if your C library is
older than its (glibc 2.40), use `--native`, or `RELINK_FEDORA=<older version>`.

## What your PC needs

- A 64-bit x86 CPU. The game is built for your CPU, so AVX2 is not required on Linux.
- A GPU with Vulkan 1.3 and mesh shaders: AMD Radeon RX 6000 or newer (RADV, Mesa's driver, which Bazzite has), NVIDIA RTX
  20 series or newer, Intel Arc. Without mesh shaders the game runs in the experimental mode, as on Windows (about half the
  frame rate, some large rocks missing). Linux has not been tested by the developers as much as Windows.
- 16 GB of RAM or more for the build (with less, use `--jobs 2`), about 60 GB free while it builds.

`linux/relink-linux.sh doctor` says what it finds on your PC.

## Updating

```bash
~/ReLink-src/linux/relink-linux.sh update ~/Games/ReLink
```

When the sources are a git checkout without local changes, this first moves them to the latest release tag, then builds the
folder again from the game files it keeps (your `.nup` is not needed again). Saves (`user`), settings and mods stay. A game
folder built from a release tag also offers the update itself at start, as on Windows (when `zenity` is installed, which
asks the question).

## Settings and files

Everything is in the game folder, as on Windows: `relink_options.ini` (the Insert menu writes it), `relink_env.txt`
(`NAME=VALUE` lines, the variables the README lists, e.g. `HOS_FPS_CAP=30`), `user` (saves), `mods`, `screenshots`.
F11 or Alt+Enter switches full screen. The window uses Wayland when there is one, else X11.

NVIDIA DLSS: add `--fetch-ngx-sdk --accept-nvidia-license` after `--` to `install` with `RELINK_NGX_SDK=<folder>` set, which
downloads NVIDIA's DLSS SDK under NVIDIA's license. AMD FSR 3.1 needs AMD's `libamd_fidelityfx_vk.so` (the FidelityFX SDK's
Vulkan backend), which ReLink does not ship on Linux: put one in the game folder, or `RX_VK_FSR_LIB=<path>` in
`relink_env.txt`, and the Upscaler row offers FSR. The game's own upscaler needs nothing.

## Uninstalling

Delete the game folder, `~/.cache/relink-builder` (the build cache), `~/.local/share/relink`,
`~/.local/share/applications/relink.desktop`, and the container image (`podman rmi` the `localhost/relink-builder` images).

## Problems

- **The build stops with "the system stopped it, most likely because the PC ran out of memory"**: build again with
  `--jobs 2` (or `RELINK_JOBS=2`).
- **Black window or no picture**: run `vulkaninfo --summary` and check the GPU is listed; the game's log is `relink_log.txt`
  in the game folder.
- Bugs: open an [issue](https://github.com/pixl27/ProjectReLink/issues) with `relink_log.txt` (and `relink_build_log.txt`
  for a build problem), and say it is Linux and which distribution.
