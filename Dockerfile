FROM ubuntu:plucky

ARG WORKSPACE=/workspace
ARG FIREFOX_DIR=$WORKSPACE/firefox-144.0
ARG SCRIPT_DIR=$WORKSPACE/eswin-scripts
ARG SYSROOT_DIR=$WORKSPACE/sysroot

ARG USER_EMAIL=chenxuan@iscas.ac.cn
ARG USER_NAME='CHEN Xuan'

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
        devscripts build-essential clang zstd libclang-dev lld nodejs cbindgen m4 git multistrap pkg-config gnutls-bin

# Prepare Rust
## # System cbindgen is 0.26.0, which is too old
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustup target add riscv64gc-unknown-linux-gnu && \
    apt remove -y cbindgen && cargo install cbindgen --force

RUN git config --global user.email $USER_EMAIL && \
    git config --global user.name $USER_NAME && \
    git config --global http.version HTTP/1.1 && \
    git config --global http.postBuffer 1048576000 && \
    git config --global https.postBuffer 1048576000 && \
    git config --global http.sslVerify false

# Prepare sysroot
##
RUN git clone --depth=1 --branch=144.0 https://github.com/rockos-riscv/cross-script-firefox $SCRIPT_DIR && \
    patch -p0 /usr/sbin/multistrap $SCRIPT_DIR/multistrap-auth.patch && \
    multistrap -a riscv64 -d $SYSROOT_DIR -f $SCRIPT_DIR/sysroot-riscv64.conf && \
    rm $SYSROOT_DIR/lib -rf && \
    ln -s usr/lib $SYSROOT_DIR/lib

# Get Firefox Source Code
RUN git clone --branch=debian/144.0-1 https://salsa.debian.org/mozilla-team/firefox.git $FIREFOX_DIR

# Create Mozconfig
WORKDIR $FIREFOX_DIR
## configuration
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
RUN ./mach configure
RUN ./mach build -j$(nproc)
RUN ./mach package
# The target tarball path is obj-riscv64-unknown-linux-gnu/dist/firefox-144.0.en-US.linux-riscv64.tar.zst
