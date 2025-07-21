# PS5-DLC Toolchain

**Single-step merger that folds any number of DLC F‑PKGs into the latest PATCH PKG.**
Pick the files → wait → get `{TITLE_ID}DLCMERGED.pkg`.

## Quick Start

```
1. Download the latest release archive.
2. Extract and run  ps5-dlc-toolchain.exe  (Win‑x64, self‑contained .NET 8).
3. Choose in order:
       • PATCH.PKG
       • BASE.PKG
       • one or more DLC.PKG
4. Wait for “(done)”.
5. Grab workspace\{TITLE_ID}DLCMERGED.pkg
```

Source PKGs stay untouched.

---

---

## Workflow

1. **Extraction** – every PKG is unpacked with `orbis-pub-cmd.exe` from Fake PKG Tools.
2. **SELF → ELF** – `eboot.bin` is converted by `SelfUtil`.
3. **DLC patch** – the ELF is rebuilt with entitlement stubs via `ps4-eboot-dlc-patcher`.
4. **Project rebuild** – `gengp4_patch.exe` regenerates a GP4; metadata is updated.
5. **Re‑package** – the patched `eboot.bin` and DLC directories are packed into a new PATCH PKG.

Helper binaries are bundled and auto‑extracted to `./data` on first run.

---


## Build from Source

```bash
dotnet publish -r win-x64 -c Release \
               -p:PublishSingleFile=true \
               -p:SelfContained=true
```

Produces a single‑file launcher that depends only on stock PowerShell 5.1.

---

## Directory Layout (after first run)

```
ps5-dlc-toolchain.exe
data/
  ├─ orbis-pub-cmd.exe
  ├─ gengp4_patch.exe
  ├─ selfutil.exe
  └─ ps4-eboot-dlc-patcher.exe
workspace/
  └─ …temp + {TITLE_ID}DLCMERGED.pkg
```

---

## Limitations

* **Patch‑only input** – requires an existing **PATCH PKG** to merge DLC; cannot build a merged PKG from a stand‑alone base game (yet).
* **Single‑executable patching** – only **`eboot.bin`** is modified. idlesauce’s upstream patcher supports additional ELFs, but this wrapper has not been extended to scan and patch them.

---

## Credits (embedded helpers)

| Executable                                   | Upstream project                                                                                                                                                                          |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **ps4-eboot-dlc-patcher.exe**                | [idlesauce/ps4-eboot-dlc-patcher](https://github.com/idlesauce/ps4-eboot-dlc-patcher) – CLI‑enabled fork at [Gudui/ps4-eboot-dlc-patcher](https://github.com/Gudui/ps4-eboot-dlc-patcher) |
| **selfutil.exe**                             | [xSpecialFoodx/SelfUtil-Patched](https://github.com/xSpecialFoodx/SelfUtil-Patched)                                                                                                       |
| **orbis-pub-cmd.exe**, **gengp4\_patch.exe** | [CyB1K/PS4-Fake-PKG-Tools-3.87](https://github.com/CyB1K/PS4-Fake-PKG-Tools-3.87)                                                                                                         |

Profound thanks to these authors for making this toolchain possible.
