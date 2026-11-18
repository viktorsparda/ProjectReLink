# ReLink on Linux (Bazzite, SteamOS, Fedora and others)

ReLink builds a native Linux game from your own copy, the same way the Windows version does: the game's code is translated
and compiled on your PC, with no emulator and no Wine or Proton. The result is a folder with `bin/relink` (the game),
`relink_vk.so` (its Vulkan renderer) and the game's files, which runs directly on your system.

**The game version you need** is the same as on Windows (program `0400486024DEC000`, update v131072, build `e0f3ccfa`), as a
`.nup` file or as its `romfs` and `exefs` folders.

## Install and play (any distribution: Bazzite, SteamOS, Fedora, Ubuntu, Arch…)

1. Download `ReLink-x86_64.AppImage` from the [latest release](https://github.com/pixl27/ProjectReLink/releases/latest).
   It brings everything the build needs (its own compiler, Python and libraries, about 210 MB): nothing to install, and
   nothing is installed on your system. On a Steam Deck or Bazzite in Gaming Mode, switch to Desktop Mode first.
2. Make it executable and open it: right-click it, **Properties → Permissions → Is executable** (KDE) or **Allow executing
   file as program** (GNOME), then double-click it. From a terminal:

   ```bash
   chmod +x ReLink-x86_64.AppImage
   ./ReLink-x86_64.AppImage
   ```

3. Pick your copy of the game. The window looks for `.nup` files in Downloads, Desktop and Documents; **File…** or
   **Folder…** (the folder holding `exefs` and `romfs`) choose another. It checks the copy and says whether it is the right
   version.
4. Choose the game folder (`~/Games/ReLink` by default) and the language, and press **Install**: 10 to 45 minutes depending
   on your CPU. **Show details** shows the build's output; it is also saved as `relink_build_log.txt` in the game folder.
5. Press **Play**. **Project ReLink** is also in your application menu from then on; it starts the game directly.

The first start prepares the shaders and pipelines once (about a quarter of an hour), with a progress screen, as on Windows.
The game's own **Insert** / **F1** menu has every setting.

The AppImage also works from a terminal, with no window:

```bash
./ReLink-x86_64.AppImage install --game ~/Downloads/<your file>.nup [--out <folder>] [--language fr] [--jobs 4]
./ReLink-x86_64.AppImage check --game ~/Downloads/<your file>.nup
./ReLink-x86_64.AppImage update [<game folder>]
./ReLink-x86_64.AppImage doctor
```

If it says FUSE is missing (some minimal systems), run it with `--appimage-extract-and-run` first, or install `fuse3`.

### In Steam and Gaming Mode

In Desktop Mode, open Steam, then **Games → Add a Non-Steam Game to My Library…**, tick **Project ReLink** and press
**Add Selected Programs**. It then shows in Gaming Mode's library. Leave its compatibility setting off: this is a native
Linux game, not one for Proton.

Controllers work through SDL (Bazzite's own): Xbox pads, DualSense, DualShock 4, Switch Pro and the Steam Deck's controls.
With Steam Input on, Steam presents them as an Xbox pad, which works too.

## Building from source, or without the AppImage

`linux/relink-linux.sh` builds from a checkout of this repository. On systems whose base cannot take packages (Bazzite,
Silverblue, SteamOS) it builds inside a **podman** container (`linux/Containerfile`: Fedora, the host's version, with clang,
Python and a static FFmpeg), so nothing is installed on the system; the finished game runs on the system itself.

```bash
git clone --depth 1 --branch <latest release tag> https://github.com/pixl27/ProjectReLink ~/ReLink-src
~/ReLink-src/linux/relink-linux.sh install --game ~/Downloads/<your file>.nup
```

The first time, it prepares the container (5 to 10 minutes, about 2 GB). `update`, `play`, `check`, `shortcut` and `doctor`
work as the AppImage's. With `--native` it uses the system's own tools instead; install:

- **Fedora**: `sudo dnf install clang lld llvm git make nasm meson ninja-build python3-pip libstdc++-static`
- **Debian, Ubuntu**: `sudo apt install clang lld llvm git make nasm meson ninja-build python3-pip`
- **Arch**: `sudo pacman -S clang lld llvm git make nasm meson ninja python-pip`

and the Python packages `capstone numpy zstandard lz4 pillow`. The first native build makes FFmpeg (only the video decoders
the game needs) and fetches the Vulkan headers into `~/.local/share/relink/deps`, once (`linux/build-deps.sh`).

The AppImage itself is made by `scripts/linux/appimage.sh` (in an Ubuntu 22.04 container), which the Linux workflow runs for
every release.

## What your PC needs

- A 64-bit x86 CPU. The game is built for your CPU, so AVX2 is not required on Linux.
- A GPU with Vulkan 1.3 and mesh shaders: AMD Radeon RX 6000 or newer (RADV, Mesa's driver, which Bazzite has), NVIDIA RTX
  20 series or newer, Intel Arc. Without mesh shaders the game runs in the experimental mode, as on Windows (about half the
  frame rate, some large rocks missing). Linux has not been tested by the developers as much as Windows.
- 16 GB of RAM or more for the build (with less, use `--jobs 2`), about 60 GB free while it builds.

`linux/relink-linux.sh doctor` says what it finds on your PC.

## Updating

When a new release is out, the game offers the update at start, as on Windows (with `zenity` installed, which asks the
question): **Update now** closes the game, downloads the new AppImage into `~/.local/share/relink/builder` and builds the
folder again in its window. Or download the new AppImage yourself, open it and press **Update**. Either way the folder is
built again from the game files it keeps (your `.nup` is not needed again), and saves (`user`), settings and mods stay.

From a checkout: `linux/relink-linux.sh update ~/Games/ReLink` first moves the sources to the latest release tag (when they
have no local changes), then builds the folder again.

## Settings and files

Everything is in the game folder, as on Windows: `relink_options.ini` (the Insert menu writes it), `relink_env.txt`
(`NAME=VALUE` lines, the variables the README lists, e.g. `HOS_FPS_CAP=30`), `user` (saves), `mods`, `screenshots`.
F11 or Alt+Enter switches full screen. The window uses Wayland when there is one, else X11.

NVIDIA DLSS: add `--fetch-ngx-sdk --accept-nvidia-license` after `--` to `install` with `RELINK_NGX_SDK=<folder>` set, which
downloads NVIDIA's DLSS SDK under NVIDIA's license. AMD FSR 3.1 needs AMD's `libamd_fidelityfx_vk.so` (the FidelityFX SDK's
Vulkan backend), which ReLink does not ship on Linux: put one in the game folder, or `RX_VK_FSR_LIB=<path>` in
`relink_env.txt`, and the Upscaler row offers FSR. The game's own upscaler needs nothing.

## Uninstalling

Delete the game folder, the AppImage, `~/.cache/relink-builder` (the build cache), `~/.local/share/relink`,
`~/.config/relink` and `~/.local/share/applications/relink.desktop`. A build from source also leaves its container image
(`podman rmi` the `localhost/relink-builder` images).

## Problems

- **The build stops with "the system stopped it, most likely because the PC ran out of memory"**: build again with
  `--jobs 2` (or `RELINK_JOBS=2`).
- **Black window or no picture**: run `vulkaninfo --summary` and check the GPU is listed; the game's log is `relink_log.txt`
  in the game folder.
- Bugs: open an [issue](https://github.com/pixl27/ProjectReLink/issues) with `relink_log.txt` (and `relink_build_log.txt`
  for a build problem), and say it is Linux and which distribution.
