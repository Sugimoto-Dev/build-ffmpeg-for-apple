# build-ffmpeg-for-apple

Build FFmpeg XCFrameworks for Apple platforms from source.

This repository has two goals:

1. Build FFmpeg and `libass` dependencies from source in GitHub Actions.
2. Provide a local macOS helper app to generate build commands and workflow inputs.

## What It Builds

The current workflow builds these FFmpeg libraries as XCFrameworks:

- `libavcodec`
- `libavdevice`
- `libavfilter`
- `libavformat`
- `libavutil`
- `libswresample`
- `libswscale`

Target platforms:

- `ios`
- `iossimulator`
- `macos`
- `tvos`
- `tvossimulator`

`avdevice` is enabled only for:

- `ios`
- `iossimulator`
- `macos`

`libass` and `drawtext` are enabled in cloud builds.

License modes:

- `lgpl`
  Default mode. Does not add `--enable-gpl`.
- `gpl`
  Explicit GPL mode. Adds `--enable-gpl` to FFmpeg configure.

## Repository Layout

- `build_ffmpeg_xcframework.swift`
  Main FFmpeg XCFramework build script.
- `build_libass_deps_from_source.sh`
  Builds `libunibreak`, `freetype`, `fribidi`, `harfbuzz`, and `libass` from source.
- `.github/workflows/build-ffmpeg.yml`
  GitHub Actions workflow for cloud builds and optional release publishing.
- `Package.swift`
  Swift package manifest for the local helper app and tests.
- `Sources/BuildFFmpegCore/Core.swift`
  Shared configuration and command-generation logic.
- `Sources/BuildFFmpegCommandBuilder/main.swift`
  SwiftUI macOS helper app.
- `Tests/BuildFFmpegCoreTests/BuildFFmpegCoreTests.swift`
  Unit tests for command generation and preset storage.

## GitHub Actions

The main workflow is manual:

- Workflow: `Build FFmpeg XCFramework`
- Trigger: `workflow_dispatch`

Inputs:

- `ffmpeg_ref`
  FFmpeg tag or branch. Default: `n8.1`
- `libass_ref`
  `libass` tag used when building dependencies from source. Default: `0.17.4`
- `license_mode`
  FFmpeg license mode. Default: `lgpl`
- `release_tag`
  Optional. If empty, the workflow uploads artifacts only. If set, it also creates or updates a GitHub Release and uploads the generated `*.xcframework.zip` and `*.sha256` files.

### Running The Workflow

From the GitHub web UI:

1. Open `Actions`.
2. Select `Build FFmpeg XCFramework`.
3. Click `Run workflow`.
4. Fill the inputs.
5. Start the run.

Suggested test values:

- `ffmpeg_ref`: `n8.1`
- `libass_ref`: `0.17.4`
- `license_mode`: `lgpl`
- `release_tag`: leave empty for artifact-only testing

Suggested release test:

- `release_tag`: `test-release-001`

### Workflow Output

When successful, the workflow:

1. Installs build tools on the macOS runner.
2. Builds `libass` dependencies from source.
3. Clones FFmpeg from the official repository.
4. Builds XCFrameworks.
5. Generates SHA256 files.
6. Uploads workflow artifacts.
7. Optionally publishes a GitHub Release.

Expected artifacts or release assets:

- `libavcodec.xcframework.zip`
- `libavdevice.xcframework.zip`
- `libavfilter.xcframework.zip`
- `libavformat.xcframework.zip`
- `libavutil.xcframework.zip`
- `libswresample.xcframework.zip`
- `libswscale.xcframework.zip`
- matching `.sha256` files

## Local Usage

### Run The SwiftUI Helper App

```bash
swift run BuildFFmpegCommandBuilder
```

The app can:

- generate a local `xcrun swift build_ffmpeg_xcframework.swift ...` command
- generate `gh workflow run ...` commands
- save and load presets
- import and export preset JSON
- trigger `gh workflow run` directly from the app
- remember the most recent configuration

### Run Tests

```bash
swift test
```

### Build The Package

```bash
swift build
```

### Manual CLI Build Examples

If you want to run the FFmpeg build script directly from terminal, use `xcrun swift`.

Minimal example:

```bash
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source /path/to/FFmpeg \
  --output /tmp/ffmpeg-out \
  --license lgpl
```

Example with explicit work directory and a smaller platform set:

```bash
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source /path/to/FFmpeg \
  --output /tmp/ffmpeg-out \
  --work /tmp/ffmpeg-work \
  --platforms macos,ios,iossimulator \
  --min-ios 14.0 \
  --min-macos 11.0 \
  --license lgpl \
  --verbose
```

Example with `libass` and dependency prefixes:

```bash
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source /path/to/FFmpeg \
  --output /tmp/ffmpeg-out \
  --work /tmp/ffmpeg-work \
  --platforms macos,ios,iossimulator \
  --license lgpl \
  --enable-libass \
  --dependency-prefix-template 'libass=/path/to/libass/{platform}/thin/{arch}' \
  --dependency-prefix-template 'freetype=/path/to/libfreetype/{platform}/thin/{arch}' \
  --dependency-prefix-template 'harfbuzz=/path/to/libharfbuzz/{platform}/thin/{arch}' \
  --dependency-prefix-template 'fribidi=/path/to/libfribidi/{platform}/thin/{arch}' \
  --dependency-prefix-template 'unibreak=/path/to/libunibreak/{platform}/thin/{arch}' \
  --verbose
```

Full workflow-aligned example:

```bash
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source /path/to/FFmpeg \
  --output /tmp/ffmpeg-out \
  --work /tmp/ffmpeg-work \
  --platforms ios,iossimulator,macos,tvos,tvossimulator \
  --min-ios 14.0 \
  --min-macos 11.0 \
  --min-tvos 14.0 \
  --license lgpl \
  --enable-libass \
  --enable-drawtext \
  --enable-avdevice \
  --avdevice-platforms ios,iossimulator,macos \
  --dependency-prefix-template 'libass=/path/to/libass/{platform}/thin/{arch}' \
  --dependency-prefix-template 'freetype=/path/to/libfreetype/{platform}/thin/{arch}' \
  --dependency-prefix-template 'harfbuzz=/path/to/libharfbuzz/{platform}/thin/{arch}' \
  --dependency-prefix-template 'fribidi=/path/to/libfribidi/{platform}/thin/{arch}' \
  --dependency-prefix-template 'unibreak=/path/to/libunibreak/{platform}/thin/{arch}' \
  --zip \
  --verbose
```

Notes:

- `--source` must point to an FFmpeg source checkout, not an installed `ffmpeg` binary.
- `--license` supports `lgpl` and `gpl`. Default is `lgpl`.
- The dependency prefix templates should point at installed prefixes for each platform and architecture.
- The current dependency layout convention is `{platform}/thin/{arch}`.
- If you only want to validate the script quickly, start with `macos,ios,iossimulator` before running the full platform set.

### fish Shell Examples

If you use `fish`, define variables first:

```fish
set -x FFMPEG_SRC /path/to/FFmpeg
set -x OUT_DIR /tmp/ffmpeg-out
set -x WORK_DIR /tmp/ffmpeg-work
set -x DEPS_ROOT /path/to/deps
```

Then run the script like this:

```fish
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source $FFMPEG_SRC \
  --output $OUT_DIR \
  --work $WORK_DIR \
  --platforms macos,ios,iossimulator \
  --license lgpl \
  --enable-libass \
  --dependency-prefix-template "libass=$DEPS_ROOT/libass/{platform}/thin/{arch}" \
  --dependency-prefix-template "freetype=$DEPS_ROOT/libfreetype/{platform}/thin/{arch}" \
  --dependency-prefix-template "harfbuzz=$DEPS_ROOT/libharfbuzz/{platform}/thin/{arch}" \
  --dependency-prefix-template "fribidi=$DEPS_ROOT/libfribidi/{platform}/thin/{arch}" \
  --dependency-prefix-template "unibreak=$DEPS_ROOT/libunibreak/{platform}/thin/{arch}" \
  --verbose
```

Full platform example:

```fish
xcrun swift ./build_ffmpeg_xcframework.swift \
  --source $FFMPEG_SRC \
  --output $OUT_DIR \
  --work $WORK_DIR \
  --platforms ios,iossimulator,macos,tvos,tvossimulator \
  --min-ios 14.0 \
  --min-macos 11.0 \
  --min-tvos 14.0 \
  --license lgpl \
  --enable-libass \
  --enable-drawtext \
  --enable-avdevice \
  --avdevice-platforms ios,iossimulator,macos \
  --dependency-prefix-template "libass=$DEPS_ROOT/libass/{platform}/thin/{arch}" \
  --dependency-prefix-template "freetype=$DEPS_ROOT/libfreetype/{platform}/thin/{arch}" \
  --dependency-prefix-template "harfbuzz=$DEPS_ROOT/libharfbuzz/{platform}/thin/{arch}" \
  --dependency-prefix-template "fribidi=$DEPS_ROOT/libfribidi/{platform}/thin/{arch}" \
  --dependency-prefix-template "unibreak=$DEPS_ROOT/libunibreak/{platform}/thin/{arch}" \
  --zip \
  --verbose
```

## GitHub CLI

If you want to trigger workflows from the helper app or from terminal:

```bash
brew install gh
gh auth login
```

The helper app expects `gh` to be available in `PATH`.

## Notes

- `.build/` is ignored via `.gitignore`. Do not commit SwiftPM build products.
- The workflow forces JavaScript actions onto Node 24 now to stay ahead of GitHub's Node 20 deprecation window.
- This repository is intended to be a build repository. Keep business code and secrets out of it.
