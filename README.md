# Samsung Firmware Forge

A standalone Linux/WSL tool for stock firmware. It does not build ROMs,
flash devices, or modify firmware files.

At startup, choose one of two separate paths:

- **One UI**: Samsung firmware through a local
  [Asgard](https://github.com/ducthoe/asgard) source checkout.
- **ColorOS**: OPPO, realme, and OnePlus Full OTA firmware through
  [OPPO OTA Downloader CLI](https://github.com/kestr31/OPPO-OTA-Downloader-CLI).

## One UI extraction modes

### `apps`

Downloads the system image needed for the application directories and writes:

```text
output/<MODEL>_<CSC>/system/system/app/
output/<MODEL>_<CSC>/system/system/priv-app/
```

This is the default and best option when you only need APKs.

### `all`

Downloads the decrypted firmware ZIP, unpacks its AP archive, splits
`super.img` when present, and extracts supported filesystems such as
`system`, `product`, `vendor`, `system_ext`, `odm`, and `*_dlkm`.
Raw images are also kept under `output/<MODEL>_<CSC>/images/`.


## ColorOS Full OTA download

Choose **ColorOS** first, then enter the device model (for example `CPH2765`).
You may optionally enter a firmware variant such as `EU`; otherwise the script
lists the Full OTA profiles it finds and asks you to choose one.

Only packages explicitly marked as **Full OTA** are accepted; incremental and
delta packages are rejected during profile selection. The script first queries
the official OPPO endpoint. If that endpoint rejects the catalog profile, the
same selected Full OTA is downloaded from its catalog URL with the published
size and MD5 checksum verified.

The archive, checksum, query response, and selected profile are written to:

```text
output/coloros/<MODEL>_<VARIANT>/
```

The ColorOS path currently downloads and verifies the complete OTA archive. It
does not attempt a generic APK extraction because ColorOS packages can use
incompatible ZIP, OZIP, OFP, OPS, or payload formats. It never flashes a device.

## Requirements and automatic setup

The script targets Linux and WSL. On every run it checks the tools it needs and
installs missing packages after the normal one-time `sudo` password prompt.
Existing packages are left untouched.

Automatic setup supports:

- Debian, Ubuntu, and WSL distributions using `apt`
- Fedora and RHEL-family distributions using `dnf`
- Arch Linux using `pacman`
- openSUSE using `zypper`

For the One UI path, it automatically checks and installs Python with `venv`,
`sudo`, `tar`, `unzip`, `lz4`, `rsync`, filesystem utilities, and an EROFS
FUSE tool (`erofsfuse` on Debian/Ubuntu or `erofs-utils` on other supported
systems).

For the ColorOS path, it checks Python with `venv` and `git`, then installs the
pinned OPPO OTA Downloader CLI revision inside the project-local `.venv`.

For `all` mode, the script also attempts to install Android utilities.
`lpunpack` is not available from every distribution repository; if it remains
missing, only `all` mode stops with an actionable message. `apps` mode works
without it.

Automatic installation requires a supported package manager and either `sudo`
or a root shell. To install the common dependencies yourself on Ubuntu/Debian:

```bash
sudo apt update
sudo apt install python3-venv unzip lz4 rsync erofsfuse android-sdk-libsparse-utils
```

## Asgard integration

On first run, the script finds the Asgard source in this order:

1. `--asgard-source /path/to/asgard`
2. The `FIRMWARE_SCRIPT_ASGARD_SOURCE` environment variable
3. `firmware-script/asgard`
4. A sibling checkout at `../asgard`
5. `/home/<user>/asgard` or `/home/aaron_pc/asgard`

It then creates a project-local `.venv` and installs Asgard from that source
in editable mode, along with `tqdm`. You only provide the model and CSC: the
script handles the Asgard commands, decryption, download resumption, and the
MonsterROM-style progress display.

## Usage

```bash
cd firmware-script
chmod +x firmware-extract.sh
./firmware-extract.sh
```

For non-interactive execution:

```bash
./firmware-extract.sh --source oneui --model SM-S938B --csc EUX --mode apps
./firmware-extract.sh --source oneui --model SM-S938B --csc EUX --mode all
./firmware-extract.sh --source coloros --model CPH2765 --region EU
./firmware-extract.sh --version
```

Firmware downloads can be several gigabytes. In `apps` mode, the final system
image is retained locally; Asgard may still need to read portions of the AP
archive to reach the requested logical partition. Image mounting can require
your `sudo` password.

## Resume after cancellation or failure

On cancellation or error, the working state remains in `.work/`. One UI uses
`.work/<MODEL>_<CSC>/`; ColorOS uses
`.work/coloros_<MODEL>_<VARIANT>/`. Starting the same selection again offers to
resume, start over, or cancel. Partial downloads remain in the output directory
and the downloader resumes them using HTTP Range requests.

## Credits

One UI firmware discovery, downloading, decryption, and streamed partition
extraction are powered by [Asgard](https://github.com/ducthoe/asgard), created
by [ducthoe](https://github.com/ducthoe). Thanks to ducthoe and the Asgard
project contributors.

ColorOS Full OTA discovery and download are powered by
[OPPO OTA Downloader CLI](https://github.com/kestr31/OPPO-OTA-Downloader-CLI)
by [kestr31](https://github.com/kestr31), distributed under GPL-3.0-only.
