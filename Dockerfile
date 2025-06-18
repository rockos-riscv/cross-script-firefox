FROM ubuntu:noble 

MAINTAINER CHEN Xuan

ARG WORKSPACE=/workspace
ARG FIREFOX_DIR=$WORKSPACE/firefox-131.0.2
ARG SCRIPT_DIR=$WORKSPACE/eswin-scripts
ARG SYSROOT_DIR=$WORKSPACE/sysroot

USER root

# Prepare Environment
RUN mkdir $WORKSPACE
WORKDIR $WORKSPACE
RUN --mount=target=/var/lib/apt/lists,type=cache,sharing=locked \
    --mount=target=/var/cache/apt,type=cache,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    sed -i 's@//.*archive.ubuntu.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list.d/ubuntu.sources && \
    apt update && \
    DEBIAN_FRONTEND=noninteractive apt install -y \
        devscripts build-essential clang lld nodejs cbindgen m4 git multistrap pkg-config

# Prepare Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustup target add riscv64gc-unknown-linux-gnu

# Prepare sysroot
RUN git clone --depth=1 https://github.com/Sakura286/cross-script-firefox $SCRIPT_DIR && \
    patch -p0 /usr/sbin/multistrap $SCRIPT_DIR/multistrap-auth.patch && \
    multistrap -a riscv64 -d $SYSROOT_DIR -f $SCRIPT_DIR/sysroot-riscv64.conf

# Get Firefox Source Code
RUN dget -u https://snapshot.debian.org/archive/debian/20250416T084123Z/pool/main/f/firefox/firefox_137.0.2-1.dsc

# Create Mozconfig
WORKDIR $FIREFOX_DIR
RUN <<EOF cat >> mozconfig
ac_add_options --enable-release
ac_add_options --enable-default-toolkit=cairo-gtk3-wayland
ac_add_options --with-google-location-service-api-keyfile=@TOPSRCDIR@/debian/google.key
ac_add_options --with-google-safebrowsing-api-keyfile=@TOPSRCDIR@/debian/google.key
ac_add_options --with-mozilla-api-keyfile=@TOPSRCDIR@/debian/mls.key
ac_add_options --with-system-zlib
ac_add_options --disable-strip
ac_add_options --disable-install-strip
ac_add_options --enable-system-ffi
ac_add_options --with-system-libevent
ac_add_options --disable-updater
ac_add_options --with-unsigned-addon-scopes=app,system
ac_add_options --allow-addon-sideload
ac_add_options --enable-alsa

# https://github.com/sunhaiyong1978/Yongbao/blob/main/loongarch64/scripts/step/desktop-app/firefox
ac_add_options --enable-linker=lld
ac_add_options --target=riscv64-linux-gnu
ac_add_options --enable-application=browser
ac_add_options --without-wasm-sandboxed-libraries
ac_add_options --with-sysroot=$SYSROOT_DIR
EOF

# Build & Package
# RUN ./mach configure
# RUN ./mach build -j$(nproc)
# RUN ./mach package
# The target tarball path is obj-riscv64-unknown-linux-gnu/dist/firefox-131.0.2.en-US.linux-riscv64.tar.bz2
