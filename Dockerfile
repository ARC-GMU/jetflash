FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Host-side dependencies for NVIDIA Jetson Linux (L4T R36.x / JetPack 6) flashing.
# This is a superset of what tools/l4t_flash_prerequisites.sh installs, so the
# image works before the BSP has even been downloaded.
RUN apt-get update && apt-get install -y --no-install-recommends \
        abootimg binfmt-support binutils bzip2 ca-certificates cpio cpp \
        device-tree-compiler dosfstools e2fsprogs file gdisk iproute2 \
        iputils-ping kmod libxml2-utils lbzip2 lz4 mtools nfs-kernel-server \
        openssh-client openssl parted python3 python3-yaml qemu-user-static \
        rpcbind sshpass sudo udev usbutils uuid-runtime wget whois xxd \
        xmlstarlet zstd pv less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

COPY jetflash.sh /usr/local/bin/jetflash.sh
RUN chmod +x /usr/local/bin/jetflash.sh

# Default container login. Change here (or with --build-arg) if you like.
ARG USERNAME=jetflash
ARG PASSWORD=jetflash
RUN useradd -m -s /bin/bash -G sudo,plugdev,dialout "$USERNAME" \
    && echo "$USERNAME:$PASSWORD" | chpasswd \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:SETENV: ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /workspace
CMD ["jetflash.sh"]
