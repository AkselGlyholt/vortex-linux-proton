# Vortex on Linux

This project launches the Windows `Vortex.exe` on x86-64 Linux with
[GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) and registers
the `vortex:` URL scheme used by [playvortex.io](https://playvortex.io).
If GE-Proton cannot be found or installed, the launcher can fall back to Wine
in a separate prefix.

The website-to-app path is:

```text
playvortex.io Play button
        |
        v
vortex: URL -> io.playvortex.Vortex.desktop
        |
        v
vortex-linux -> GE-Proton -> Vortex.exe "vortex:..."
```

The URL is passed as one literal process argument. The launcher accepts only
the `vortex:` scheme and never evaluates the URL as shell code.

## Install

Requirements:

- x86-64 Linux
- `curl`, `unzip`, `tar`, `sha512sum`, `file`, `xdg-mime`, and Python 3
- working Vulkan graphics drivers are strongly recommended
- enough free disk space for GE-Proton, its prefix, and the client download

Run:

```bash
./install.sh
```

This is a per-user install and does not use `sudo`. It:

1. downloads the current official Windows client from
   `https://playvortex.io/download/windows`, then installs it and the launcher
   under
   `${XDG_DATA_HOME:-~/.local/share}/vortex-linux`;
2. applies a hash-locked swap-chain timeout recovery patch to supported builds,
   retaining the original executable beside it as `Vortex.exe.unpatched`;
3. reuses an existing GE-Proton when one is available, otherwise downloads the
   latest release from GloriousEggroll's official GitHub repository;
4. verifies the release's SHA-512 checksum before extracting it;
5. creates a persistent Proton prefix;
6. registers `x-scheme-handler/vortex` with the desktop.

Restart an already-open browser after installation. Sign in to
`https://playvortex.io`, choose a game, click **Play**, and approve the browser's
one-time external-application prompt.

To use a Vortex executable you already downloaded instead:

```bash
./install.sh --exe /path/to/Vortex.exe
```

To avoid downloading GE-Proton and use an existing GE-Proton or Wine:

```bash
./install.sh --no-proton-download
```

To install without modifying a supported client executable:

```bash
./install.sh --no-client-patch
```

## Commands

Launch directly:

```bash
vortex-linux
```

Check the runtime and URL association:

```bash
vortex-linux --doctor
```

Update GE-Proton:

```bash
vortex-linux --install-proton
```

Force a runtime for troubleshooting:

```bash
vortex-linux --runtime proton
vortex-linux --runtime wine
```

Run attached to the terminal:

```bash
vortex-linux --foreground
```

Logs are written to
`${XDG_STATE_HOME:-~/.local/state}/vortex-linux/launcher.log`. Launch URLs are
passed to the transient user service through a private, one-use runtime file.
They are not written by the wrapper or placed in systemd service arguments
because they may contain short-lived authentication material.

## Runtime overrides

The launcher supports:

| Variable | Purpose |
| --- | --- |
| `VORTEX_PROTON` | GE-Proton directory or executable `proton` script |
| `VORTEX_RUNTIME` | `auto` (default), `proton`, or `wine` |
| `VORTEX_WINE` | Wine executable used by fallback mode |
| `VORTEX_DATA_HOME` | Install/runtime/prefix directory |
| `VORTEX_COMPAT_DATA` | Proton compatdata directory |
| `VORTEX_WINEPREFIX` | Wine fallback prefix |
| `VORTEX_STEAM_ROOT` | Steam client root supplied to Proton |
| `PROTON_USE_WINED3D=1` | Use OpenGL when Vulkan/DXVK is broken |
| `PROTON_DISABLE_HIDRAW` | Defaults to `1` to avoid Wine's incomplete Windows Gaming Input path; explicitly set it to override |

GE-Proton is the normal path. Wine is selected automatically only if no
GE-Proton is available, or explicitly with `--runtime wine`.

The current Windows client bundles `gilrs-core 0.6.7`, which crashes under Wine
when a HID device is exposed through Windows Gaming Input because Wine has not
implemented `RawGameController.NonRoamableId`. The default hidraw setting avoids
that crash. On systems where a controller is required, its SDL-backed behavior
depends on the controller and GE-Proton version.

## Vortex timeout patch

The Windows build also compiles Bevy's Windows behavior for
`wgpu::SurfaceError::Timeout`: it treats a transient swap-chain timeout as
unrecoverable and panics. This is reproducible with NVIDIA Vulkan through
Xwayland.

For the exact supported v0.2.13 and v0.2.16 executables, the installer applies
a one-byte x86-64 patch to Bevy's `prepare_windows` match arm. It changes the
conditional branch from `JNE` to unsigned `JA`, so error discriminators `0`
(`Timeout`) and `1` (`Outdated`) both use Bevy's existing surface
reconfigure/retry path. `Lost` and `OutOfMemory` retain their original fatal
behavior.

The patcher requires both the complete original SHA-256 and the surrounding
instruction bytes to match before writing anything. The patched result is also
checked against a complete SHA-256. Inspect or reverse it with:

```bash
patch-vortex-exe --check ~/.local/share/vortex-linux/app/Vortex.exe
patch-vortex-exe --restore ~/.local/share/vortex-linux/app/Vortex.exe
```

## Uninstall

Remove the program and desktop integration while retaining downloaded runtimes
and prefixes:

```bash
./uninstall.sh
```

Remove everything, including prefixes, cached runtime, and logs:

```bash
./uninstall.sh --purge
```

`--purge` permanently removes local Vortex/Proton data.

## Development

Run the integration tests:

```bash
make test
```

The tests use stub client downloads, Proton, and Wine executables; they verify
the installer and exact URL argument handling without downloading the real
client, starting a game, or modifying the user's desktop settings.

## Scope

This is an unofficial compatibility launcher. It does not modify
`playvortex.io` or bypass authentication. Its narrowly scoped, reversible
client patch is applied only to exact supported executable hashes. Unknown
releases are installed without modification and produce a warning; they may
already contain an upstream fix, otherwise their patch must be reviewed and
added explicitly. The live Vortex download page currently labels native Linux
support as forthcoming, so behavior can change when an official client is
released.
