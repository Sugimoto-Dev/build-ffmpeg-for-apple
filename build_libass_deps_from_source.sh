#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work-deps}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/deps}"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/src-deps}"
JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

LIBUNIBREAK_REPO="${LIBUNIBREAK_REPO:-https://github.com/adah1972/libunibreak.git}"
LIBUNIBREAK_REF="${LIBUNIBREAK_REF:-libunibreak_6_1}"
FREETYPE_REPO="${FREETYPE_REPO:-https://github.com/freetype/freetype.git}"
FREETYPE_REF="${FREETYPE_REF:-VER-2-13-3}"
FRIBIDI_REPO="${FRIBIDI_REPO:-https://github.com/fribidi/fribidi.git}"
FRIBIDI_REF="${FRIBIDI_REF:-v1.0.16}"
HARFBUZZ_REPO="${HARFBUZZ_REPO:-https://github.com/harfbuzz/harfbuzz.git}"
HARFBUZZ_REF="${HARFBUZZ_REF:-8.1.1}"
LIBASS_REPO="${LIBASS_REPO:-https://github.com/libass/libass.git}"
LIBASS_REF="${LIBASS_REF:-0.17.4}"

PLATFORMS=(ios isimulator macos tvos tvsimulator)

log() {
  printf '[build_libass_deps] %s\n' "$*"
}

ensure_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

clone_source() {
  local name="$1"
  local repo="$2"
  local ref="$3"
  local dest="$SRC_DIR/$name"

  if [ -d "$dest/.git" ]; then
    log "Reusing source $name"
    return
  fi

  rm -rf "$dest"
  log "Cloning $name from $repo @ $ref"
  git clone --depth 1 --branch "$ref" "$repo" "$dest"
}

platform_sdk() {
  case "$1" in
    ios) echo "iphoneos" ;;
    isimulator) echo "iphonesimulator" ;;
    macos) echo "macosx" ;;
    tvos) echo "appletvos" ;;
    tvsimulator) echo "appletvsimulator" ;;
    *) echo "Unsupported platform: $1" >&2; exit 1 ;;
  esac
}

platform_arches() {
  case "$1" in
    ios) echo "arm64" ;;
    isimulator) echo "arm64 x86_64" ;;
    macos) echo "arm64 x86_64" ;;
    tvos) echo "arm64" ;;
    tvsimulator) echo "arm64 x86_64" ;;
    *) echo "Unsupported platform: $1" >&2; exit 1 ;;
  esac
}

platform_min_version() {
  case "$1" in
    ios|isimulator) echo "14.0" ;;
    macos) echo "11.0" ;;
    tvos|tvsimulator) echo "14.0" ;;
    *) echo "Unsupported platform: $1" >&2; exit 1 ;;
  esac
}

platform_target() {
  local platform="$1"
  local arch="$2"
  local min_version
  min_version="$(platform_min_version "$platform")"

  case "$platform" in
    ios) echo "${arch}-apple-ios${min_version}" ;;
    isimulator) echo "${arch}-apple-ios${min_version}-simulator" ;;
    macos) echo "${arch}-apple-macos${min_version}" ;;
    tvos) echo "${arch}-apple-tvos${min_version}" ;;
    tvsimulator) echo "${arch}-apple-tvos${min_version}-simulator" ;;
    *) echo "Unsupported platform: $platform" >&2; exit 1 ;;
  esac
}

platform_host() {
  local platform="$1"
  local arch="$2"
  case "$platform" in
    ios|isimulator)
      if [ "$arch" = "arm64" ]; then
        echo "aarch64-apple-darwin"
      else
        echo "x86_64-apple-darwin"
      fi
      ;;
    macos)
      if [ "$arch" = "arm64" ]; then
        echo "aarch64-apple-darwin"
      else
        echo "x86_64-apple-darwin"
      fi
      ;;
    tvos|tvsimulator)
      if [ "$arch" = "arm64" ]; then
        echo "aarch64-apple-darwin"
      else
        echo "x86_64-apple-darwin"
      fi
      ;;
    *)
      echo "Unsupported platform: $platform" >&2
      exit 1
      ;;
  esac
}

platform_cmake_system_name() {
  case "$1" in
    ios|isimulator) echo "iOS" ;;
    macos) echo "Darwin" ;;
    tvos|tvsimulator) echo "tvOS" ;;
    *) echo "Unsupported platform: $1" >&2; exit 1 ;;
  esac
}

deployment_flag() {
  local platform="$1"
  local min_version="$2"
  case "$platform" in
    ios) echo "-miphoneos-version-min=${min_version}" ;;
    isimulator) echo "-mios-simulator-version-min=${min_version}" ;;
    macos) echo "-mmacosx-version-min=${min_version}" ;;
    tvos) echo "-mtvos-version-min=${min_version}" ;;
    tvsimulator) echo "-mtvos-simulator-version-min=${min_version}" ;;
    *) echo "" ;;
  esac
}

prefix_for() {
  local name="$1"
  local platform="$2"
  local arch="$3"
  echo "$OUT_DIR/$name/$platform/thin/$arch"
}

scratch_for() {
  local name="$1"
  local platform="$2"
  local arch="$3"
  echo "$WORK_DIR/$name/$platform/$arch"
}

reset_toolchain_env() {
  unset SDKROOT
  unset CC
  unset CXX
  unset AR
  unset AS
  unset LD
  unset RANLIB
  unset STRIP
  unset NM
  unset CFLAGS
  unset CXXFLAGS
  unset CPPFLAGS
  unset LDFLAGS
  unset PKG_CONFIG_LIBDIR
}

common_env() {
  local platform="$1"
  local arch="$2"
  local sdk sdk_path target min_version dep_flag

  reset_toolchain_env

  sdk="$(platform_sdk "$platform")"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  target="$(platform_target "$platform" "$arch")"
  min_version="$(platform_min_version "$platform")"
  dep_flag="$(deployment_flag "$platform" "$min_version")"

  export SDKROOT="$sdk_path"
  export CC="$(xcrun --sdk "$sdk" --find clang)"
  export CXX="$(xcrun --sdk "$sdk" --find clang++)"
  export AR="$(xcrun --sdk "$sdk" --find ar)"
  export AS="$CC"
  export LD="$CC"
  export RANLIB="$(xcrun --sdk "$sdk" --find ranlib)"
  export STRIP="$(xcrun --sdk "$sdk" --find strip)"
  export NM="$(xcrun --sdk "$sdk" --find nm)"
  export CFLAGS="-arch $arch -target $target -isysroot $sdk_path $dep_flag"
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS="$CFLAGS"
  export LDFLAGS="-arch $arch -target $target -isysroot $sdk_path $dep_flag"
}

write_freetype_pc() {
  local prefix="$1"
  mkdir -p "$prefix/lib/pkgconfig"
  cat > "$prefix/lib/pkgconfig/freetype2.pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: FreeType 2
URL: https://freetype.org
Description: A free, high-quality, and portable font engine.
Version: 24.3.18
Requires:
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}/freetype2
EOF
}

create_meson_cross_file() {
  local platform="$1"
  local arch="$2"
  local cross_file="$3"
  local sdk sdk_path sys_name cpu_family cpu target dep_flag min_version

  sdk="$(platform_sdk "$platform")"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  sys_name="$(platform_cmake_system_name "$platform")"
  min_version="$(platform_min_version "$platform")"
  dep_flag="$(deployment_flag "$platform" "$min_version")"
  target="$(platform_target "$platform" "$arch")"

  if [ "$arch" = "x86_64" ]; then
    cpu_family="x86_64"
    cpu="x86_64"
  else
    cpu_family="aarch64"
    cpu="arm64"
  fi

  cat > "$cross_file" <<EOF
[binaries]
c = '$(xcrun --sdk "$sdk" --find clang)'
cpp = '$(xcrun --sdk "$sdk" --find clang++)'
ar = '$(xcrun --sdk "$sdk" --find ar)'
strip = '$(xcrun --sdk "$sdk" --find strip)'
pkg-config = '$(command -v pkg-config)'

[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$cpu'
endian = 'little'

[built-in options]
c_args = ['-arch', '$arch', '-target', '$target', '-isysroot', '$sdk_path', '$dep_flag']
cpp_args = ['-arch', '$arch', '-target', '$target', '-isysroot', '$sdk_path', '$dep_flag']
c_link_args = ['-arch', '$arch', '-target', '$target', '-isysroot', '$sdk_path', '$dep_flag']
cpp_link_args = ['-arch', '$arch', '-target', '$target', '-isysroot', '$sdk_path', '$dep_flag']
default_library = 'static'
buildtype = 'release'
EOF
}

build_libunibreak() {
  local src="$SRC_DIR/libunibreak"

  for platform in "${PLATFORMS[@]}"; do
    for arch in $(platform_arches "$platform"); do
      local prefix scratch host
      prefix="$(prefix_for libunibreak "$platform" "$arch")"
      scratch="$(scratch_for libunibreak "$platform" "$arch")"
      host="$(platform_host "$platform" "$arch")"

      rm -rf "$scratch" "$prefix"
      mkdir -p "$scratch" "$prefix"
      common_env "$platform" "$arch"

      log "Building libunibreak for $platform $arch"
      (
        cd "$src"
        [ -f configure ] || ./bootstrap
      )
      (
        cd "$scratch"
        "$src/configure" \
          --host="$host" \
          --prefix="$prefix" \
          --disable-shared \
          --enable-static
        make -j"$JOBS"
        make install
      )
    done
  done
}

build_freetype() {
  local src="$SRC_DIR/freetype"

  for platform in "${PLATFORMS[@]}"; do
    for arch in $(platform_arches "$platform"); do
      local prefix scratch sdk sdk_path system_name min_version
      prefix="$(prefix_for libfreetype "$platform" "$arch")"
      scratch="$(scratch_for libfreetype "$platform" "$arch")"
      sdk="$(platform_sdk "$platform")"
      sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
      system_name="$(platform_cmake_system_name "$platform")"
      min_version="$(platform_min_version "$platform")"
      reset_toolchain_env

      rm -rf "$scratch" "$prefix"
      mkdir -p "$scratch" "$prefix"

      log "Building freetype for $platform $arch"
      cmake -S "$src" -B "$scratch" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$system_name" \
        -DCMAKE_C_COMPILER="$(xcrun --sdk "$sdk" --find clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun --sdk "$sdk" --find clang++)" \
        -DCMAKE_OSX_SYSROOT="$sdk_path" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_version" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_BROTLI=TRUE \
        -DFT_DISABLE_BZIP2=TRUE \
        -DFT_DISABLE_HARFBUZZ=TRUE \
        -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_ZLIB=TRUE
      cmake --build "$scratch" --parallel "$JOBS"
      cmake --install "$scratch"
      write_freetype_pc "$prefix"
    done
  done
}

build_fribidi() {
  local src="$SRC_DIR/fribidi"

  for platform in "${PLATFORMS[@]}"; do
    for arch in $(platform_arches "$platform"); do
      local prefix scratch cross_file
      prefix="$(prefix_for libfribidi "$platform" "$arch")"
      scratch="$(scratch_for libfribidi "$platform" "$arch")"
      cross_file="$scratch/cross.txt"

      reset_toolchain_env
      rm -rf "$scratch" "$prefix"
      mkdir -p "$scratch" "$prefix"
      create_meson_cross_file "$platform" "$arch" "$cross_file"

      log "Building fribidi for $platform $arch"
      meson setup "$scratch/build" "$src" \
        --cross-file "$cross_file" \
        --prefix "$prefix" \
        --default-library static \
        -Ddocs=false \
        -Dbin=false \
        -Dtests=false
      meson compile -C "$scratch/build" -j "$JOBS"
      meson install -C "$scratch/build"
    done
  done
}

build_harfbuzz() {
  local src="$SRC_DIR/harfbuzz"

  for platform in "${PLATFORMS[@]}"; do
    for arch in $(platform_arches "$platform"); do
      local prefix scratch cross_file pkg_path
      prefix="$(prefix_for libharfbuzz "$platform" "$arch")"
      scratch="$(scratch_for libharfbuzz "$platform" "$arch")"
      cross_file="$scratch/cross.txt"

      reset_toolchain_env
      rm -rf "$scratch" "$prefix"
      mkdir -p "$scratch" "$prefix"
      create_meson_cross_file "$platform" "$arch" "$cross_file"

      pkg_path="$(prefix_for libfreetype "$platform" "$arch")/lib/pkgconfig:$(prefix_for libfribidi "$platform" "$arch")/lib/pkgconfig"

      log "Building harfbuzz for $platform $arch"
      PKG_CONFIG_LIBDIR="$pkg_path" \
      meson setup "$scratch/build" "$src" \
        --cross-file "$cross_file" \
        --prefix "$prefix" \
        --default-library static \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dintrospection=disabled \
        -Dchafa=disabled \
        -Dcoretext=disabled \
        -Dfreetype=enabled
	# -Dbenchmarks=disabled \
      PKG_CONFIG_LIBDIR="$pkg_path" meson compile -C "$scratch/build" -j "$JOBS"
      PKG_CONFIG_LIBDIR="$pkg_path" meson install -C "$scratch/build"
    done
  done
}

build_libass() {
  local src="$SRC_DIR/libass"

  for platform in "${PLATFORMS[@]}"; do
    for arch in $(platform_arches "$platform"); do
      local prefix scratch host pkg_path
      prefix="$(prefix_for libass "$platform" "$arch")"
      scratch="$(scratch_for libass "$platform" "$arch")"
      host="$(platform_host "$platform" "$arch")"

      rm -rf "$scratch" "$prefix"
      mkdir -p "$scratch" "$prefix"
      common_env "$platform" "$arch"

      pkg_path="$(prefix_for libfreetype "$platform" "$arch")/lib/pkgconfig:$(prefix_for libfribidi "$platform" "$arch")/lib/pkgconfig:$(prefix_for libharfbuzz "$platform" "$arch")/lib/pkgconfig:$(prefix_for libunibreak "$platform" "$arch")/lib/pkgconfig"

      log "Building libass for $platform $arch"
      (
        cd "$src"
        [ -f configure ] || ./autogen.sh
      )
      (
        cd "$scratch"
        PKG_CONFIG_LIBDIR="$pkg_path" \
        "$src/configure" \
          --host="$host" \
          --prefix="$prefix" \
          --disable-shared \
          --enable-static \
          --disable-fontconfig
        PKG_CONFIG_LIBDIR="$pkg_path" make -j"$JOBS"
        PKG_CONFIG_LIBDIR="$pkg_path" make install
      )
    done
  done
}

main() {
  ensure_tool git
  ensure_tool xcrun
  ensure_tool cmake
  ensure_tool meson
  ensure_tool ninja
  ensure_tool pkg-config

  mkdir -p "$WORK_DIR" "$OUT_DIR" "$SRC_DIR"

  clone_source libunibreak "$LIBUNIBREAK_REPO" "$LIBUNIBREAK_REF"
  clone_source freetype "$FREETYPE_REPO" "$FREETYPE_REF"
  clone_source fribidi "$FRIBIDI_REPO" "$FRIBIDI_REF"
  clone_source harfbuzz "$HARFBUZZ_REPO" "$HARFBUZZ_REF"
  clone_source libass "$LIBASS_REPO" "$LIBASS_REF"

  build_libunibreak
  build_freetype
  build_fribidi
  build_harfbuzz
  build_libass

  log "Dependency build finished"
}

main "$@"
