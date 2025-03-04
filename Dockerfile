FROM ubuntu:noble 

MAINTAINER CHEN Xuan 

ARG WORKSPACE=/workspace
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
        devscripts build-essential clang nodejs cbindgen m4 git multistrap && \
    git config --global user.email $USER_EMAIL && \
    git config --global user.name $USER_NAME

# Prepare Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . "$HOME/.cargo/env" && \
    rustup target add riscv64gc-unknown-linux-gnu

# Prepare sysroot
RUN git clone --depth=1 https://github.com/Sakura286/cross-firefox-es $SCRIPT_DIR && \
    patch -p0 /usr/sbin/multistrap $SCRIPT_DIR/multistrap-auth.patch && \
    multistrap -a riscv64 -d $SYSROOT_DIR -f $SCRIPT_DIR/sysroot-riscv64.conf


# Get Firefox Source Code
RUN dget -u https://fast-mirror.isrc.ac.cn/rockos/20250130/rockos-addons/pool/main/f/firefox/firefox_131.0.2-1rockos1.dsc

# Get depot_tools
RUN git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
RUN echo 'export PATH='$WORKSPACE'/depot_tools:$PATH' >> ~/.bashrc 
ENV PATH="$WORKSPACE/depot_tools:$PATH"

# Get Source Code
# TODO: Use rockos source repo and patch the patches seperately
RUN git clone --depth=1 https://github.com/rockos-riscv/chromium-129.0.6668.100 $CHROMIUM_DIR && \
    cd $CHROMIUM_DIR && \
    git remote add sakura286 https://github.com/Sakura286/chromium-rokcos.git && \
    git fetch sakura286 && \
    git switch -c cross-build sakura286/master
RUN $CHROMIUM_DIR/build/install-build-deps.sh

# Prepare Sysroot
## (1) Patch multistrap
RUN patch -p0 /usr/sbin/multistrap $SCRIPT_DIR/multistrap-auth.patch
WORKDIR $CHROMIUM_DIR 
## (2) Get riscv64 sysroot
### You can also run
###   multistrap -a riscv64 -d build/linux/debian_sid_riscv64-sysroot -f $SCRIPT_DIR/sysroot-riscv64.conf
### to get riscv64 sysroot here
RUN cd build/linux/ && \
    wget http://etherpad.sakura286.ink/share/debian_sid_riscv64-sysroot-0110.tar.gz && \
    tar xf debian_sid_riscv64-sysroot-0110.tar.gz && \
    cd debian_sid_riscv64-sysroot && \
    mv usr/lib/riscv64-linux-gnu/pkgconfig/* usr/lib/pkgconfig/ && \
    rm -f usr/bin/python* 
## (3) Get amd64 chroot
### TODO: Check bookwork and bullseye chroot define in gn files
RUN multistrap -a amd64 -d build/linux/debian_bookworm_amd64-sysroot -f $SCRIPT_DIR/sysroot-amd64.conf 
RUN cd build/linux/debian_bookworm_amd64-sysroot && \
    mv usr/lib/x86_64-linux-gnu/pkgconfig/* usr/lib/pkgconfig/ && \
    rm -f usr/bin/python* && \
    cd usr/lib/x86_64-linux-gnu/ && \
    for i in $(find . -type l -lname '/*' | grep lib); do STR=$(ls -l $i); rm $i; ln -s ./$(echo $STR | sed 's/  */ /g' | cut -d' ' -f 11 | cut -d'/' -f 4) $i; done
RUN mkdir -p third_party/llvm-build-tools && \
    ln -s ../../build/linux/debian_sid_riscv64-sysroot third_party/llvm-build-tools/debian_sid_riscv64_sysroot && \
    ln -s ../../build/linux/debian_bookworm_amd64-sysroot third_party/llvm-build-tools/debian_bookworm_amd64-sysroot

# Build LLVM, then rust
WORKDIR $CHROMIUM_DIR
RUN tools/clang/scripts/package.py
RUN git pull sakura286
RUN tools/rust/package_rust.py

# Build GN
WORKDIR $WORKSPACE
RUN git clone https://gn.googlesource.com/gn && \
    cd gn && \
    CXX=$LLVM_DIR/clang++ AR=$LLVM_DIR/llvm-ar python3 build/gen.py && \
    ninja -C out
RUN echo 'export PATH='$WORKSPACE'/gn/out:$PATH' >> ~/.bashrc
ENV PATH="$WORKSPACE/gn/out:$WORKSPACE/depot_tools:$PATH"

# Configure node support
WORKDIR $CHROMIUM_DIR
RUN mkdir -p third_party/node/linux/node-linux-x64/bin && \
    cp /usr/bin/node third_party/node/linux/node-linux-x64/bin && \
    cp -ra /usr/share/nodejs/rollup third_party/node/node_modules/

# Prefer unbundled (system) library
RUN debian/scripts/unbundle

# Configure chromium
RUN $SCRIPT_DIR/configure.sh

# Some other hack
## v8_snapshot_generator use some lib that only exist in amd64 sysroot
RUN apt install -y libjpeg62 && cp third_party/llvm-build-tools/debian_bullseye_amd64_sysroot/usr/lib/x86_64-linux-gnu/libdav1d.so.6 /usr/lib/x86_64-linux-gnu/

# Source: Build chromium
## Build: /workspace/eswin-scripts/build.sh
## Package: /workspace/eswin-scripts/package.sh
## The packaged file will be chromium-dist.zst