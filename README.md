# DiscMate

**English** · [简体中文](README.zh-CN.md)

DiscMate is a free optical disc burner for Apple Silicon Macs. Use it to burn a blank data DVD+R or add files and folders to an appendable disc. Each new session writes the new files and an updated directory. Existing files keep their original locations on the disc.

## Can I append to my disc?

**Three DVD+R filesystem layouts have passed physical append and readback tests.** The layout describes how the disc stores its directory. Photos, ZIP archives and documents can all be burned as ordinary files.

| Existing DVD+R layout | What you can add | Physical test results |
| --- | --- | --- |
| ISO 9660 with Joliet | Files and folders, including nested folders, Chinese names and empty directories. Each new file and the new session image must be under 4 GiB. | Across multiple appends, file hashes matched after readback and existing files kept their original locations. |
| Hybrid ISO / UDF 1.02 | Files in the root directory, up to 32 files in total. Each new file must be nonempty and under 1 GiB. The UDF root directory must fit in one sector. | After reinsertion, both directories were checked for filenames and the old and new files were read back and verified by hash. |
| Pure UDF 1.02, single physical partition | Files and directories. Each existing file must occupy one contiguous extent. Each new file must be nonempty and under 1 GiB. | One photo was added to a disc containing 89 files. After reinsertion, all 90 file hashes matched. |

**Layouts still awaiting physical append verification**

- **UDF 2.01 with a virtual allocation table (VAT).** Five existing files were read from a physical DVD+R. A new file has been added only to an offline test image. Writing, finalizing, ejecting and verifying the old and new files after reinsertion remain untested on this layout.
- **ISO 9660 with only a primary directory.** Files were extracted from an offline multisession image and their hashes matched. A physical append and readback remain unverified.

CDs, other DVD media and Blu-ray discs have yet to pass equivalent append tests. The disc must allow another session and have enough free space. DiscMate checks the session, directory and available space when you review the burn summary.

## Burn, append and verify

1. **Add files.** In the data disc view (数据光盘), select files or folders, drag them from Finder, or paste them with ⌘V. Pasting plain text creates a TXT file of up to 1 MiB.
2. **Review the burn summary** (查看刻录摘要). For a blank disc, leave multisession enabled if you plan to add files later. For an existing disc, select only the new items. DiscMate reads the old directory and file locations, so preparing an append does not require reading all the old file contents. Folders at the same path can merge. Existing files cannot be overwritten.
3. **Confirm and burn.** System verification after writing is optional and off by default. Keep the drive connected and powered through writing and finalization. If the final drive state is unclear, use the device recheck action (重新检查设备).
4. **Reinsert the disc and check the files.** If Finder shows an earlier session, choose 在访达打开最新内容 and authorize a read-only mount. Readback verification (读回校验) can check just the new files or read the whole disc. Files with a source manifest can be verified against their SHA-256 hashes.

## Other features

- Create audio CDs, burn disc images or existing VIDEO_TS folders, erase rewritable media, and inspect disc information.
- Manually close a recognized unfinished DVD+R session or write to an eligible blank reserved track. Closing a reserved track consumes its full capacity. The burn summary shows the space required before you confirm.
- Choose a burn speed and follow the current stage and elapsed time. If a task fails, preview or export its redacted diagnostic report to check drive state, USB errors and finalization events.

## Install and update

Requires an Apple Silicon Mac running macOS 13 or later and a burner compatible with your media.

```sh
brew install --cask loprx/tap/discmate
```

To update an existing installation, run

```sh
brew update
brew upgrade --cask loprx/tap/discmate
```

You can also check for updates in DiscMate settings. The app in the downloadable ZIP is ad hoc signed and has not been notarized by Apple. If macOS prompts on first launch, follow Apple’s instructions for opening an individual app. [Downloads and checksums](https://github.com/loprx/discmate/releases) · [Apple’s instructions](https://support.apple.com/102445)

## Build from source

Install the Xcode Command Line Tools, then run the commands below. Tests use local images. The build produces `build/DiscMate.app`.

```sh
zsh test.sh
zsh test.sh --large-iso  # Optional 1.12 GB offline regression
zsh build.sh
```

[Changelog (Chinese)](CHANGELOG.md) · [MIT license](LICENSE)

## Contributing and releases

Branch from the public repository’s `main` branch and open a pull request. Describe the user-visible change in the title, which appears in the release notes. Use `bug` for fixes, `enhancement` or `accessibility` for improvements, and `documentation` for docs. Other pull requests appear under “Other updates”.

After merging the release’s pull requests, tag the release commit on public `main` (for example, `v0.5.2`). GitHub Actions tests, builds and publishes the package, generates release notes from merged pull requests, and updates the Homebrew cask.
