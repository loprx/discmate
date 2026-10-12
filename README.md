# DiscMate

DiscMate is a free macOS optical disc burning prototype for Apple Silicon. Its tested incremental data workflow targets DVD+R with a flat ISO 9660/Joliet directory. The app can add files in a later session while referencing existing file extents, so an old large file does not need to be copied into each new session.

## Install

On Apple Silicon with macOS 13 or later:

```sh
brew install --cask loprx/tap/discmate
```

The package comes from the project's own [Homebrew tap](https://github.com/loprx/homebrew-tap), not Homebrew's official cask repository. macOS may require approving the first launch in System Settings → Privacy & Security → Open Anyway.

Open the app's Help menu and choose “DiscMate 使用帮助” for the current burn and append workflow.
Adding files refreshes the current disc state once, so an already inserted data disc shows the append review control without a separate manual refresh.

## Status

Developer preview. This source tree has passed local arm64 builds and offline ISO tests. One test DVD+R has passed several incremental sessions; the newest added file was read back from the latest mounted session. Automatic eject has shown an intermittent failure, and the fallback path after a burn still needs hardware validation. Other disc types and operating systems are outside the tested support range. The latest-session mount helper currently uses a deprecated authorization API, so future macOS compatibility needs further work.

## Build from source

Requires macOS 13 or later, Apple Silicon, Xcode Command Line Tools and `hdiutil`. No third-party burning backend is required.

```sh
zsh test.sh
zsh build.sh
```

The result is `build/DiscMate.app`. Building and testing do not write to a disc. Actual burning requires a selected optical drive and a disc in the app. The default build is ad hoc signed. If macOS blocks first launch of a downloaded copy, approve it in System Settings → Privacy & Security → Open Anyway.

## Current data append limits

- DVD+R with ISO 9660/Joliet and ordinary files in the root directory.
- Each file and the new session image must be under 4 GiB.
- No folder append, overwrite of an existing name, or promise that Finder automatically selects the newest session.
- Standard append checks old directory and extents, but does not reread every byte of old files. New-file and full-disc readback are separate actions.

Other controls use macOS DiscRecording, but have not all received equivalent real-disc validation. Contributions and reproducible reports are welcome.

## License

MIT. See [LICENSE](LICENSE).
