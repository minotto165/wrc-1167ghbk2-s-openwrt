# 実機に近い環境で setup.sh を走らせるための作業用イメージ
#   debian bookworm (arm64) + qemu-user-static(mipsel) + squashfs-tools + ash 系シェル
# 使い方:
#   docker build -t openwrt-emul:1 ~/openwrt-setup/emul
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        qemu-user-static squashfs-tools file busybox-static dash xxd \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /w
