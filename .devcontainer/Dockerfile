# Official Swift image (based on Ubuntu 24.04 "noble"). Ships swift, swiftc,
# swift-format, LLDB, and SPM out of the box.
#
# This container cannot build the app. A tvOS app built from an Xcode project
# needs Xcode, the Apple SDKs and a simulator, none of which exist on linux, and
# `import SwiftUI` / `import TVUIKit` do not resolve here. What it does give you
# is swift-format and SwiftLint (both SwiftSyntax only, no SDK required), a
# linux Swift toolchain for any SDK-independent code, and the agent tooling.
# Compilation, tests and signing stay on a Mac.
#
# 6.2 is the toolchain Xcode 26 ships, so swift-format here applies the same
# rules as `xcrun swift-format` on the Mac and as the CI format job. Bump all
# three together.
FROM swift:6.2-noble

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git git-filter-repo sudo openssh-client zsh tzdata locales unzip \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# SwiftLint。swift-format には無いサイズ・複雑度・安全性のルールを担当する
# (役割分担は .swiftlint.yml の先頭に書いてある)。
#
# 配布 zip には動的リンク版の `swiftlint` と完全静的リンクの `swiftlint-static`
# が入っている。後者を採用しているのは、SwiftLint のビルドに使われた Swift
# ランタイムとベースイメージの 6.2 がずれても壊れないため。バージョンを上げる
# ときは .github/workflows/integration.yaml も一緒に動かすこと。
ARG SWIFTLINT_VERSION=0.65.1
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/swiftlint.zip \
        "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux_${arch}.zip" \
    && unzip -j /tmp/swiftlint.zip swiftlint-static -d /usr/local/bin \
    && mv /usr/local/bin/swiftlint-static /usr/local/bin/swiftlint \
    && chmod +x /usr/local/bin/swiftlint \
    && rm /tmp/swiftlint.zip \
    && swiftlint version

# The swift base image is root-only; create the vscode user devcontainer runs as.
# Ubuntu 24.04 ("noble") ships a default `ubuntu` account that already holds
# uid/gid 1000, so it is removed first: without this, groupadd exits 4 with
# "GID '1000' already exists" and the image never builds.
RUN if getent passwd $USER_UID >/dev/null; then \
        userdel --remove "$(getent passwd $USER_UID | cut -d: -f1)" 2>/dev/null || true; \
    fi \
    && if getent group $USER_GID >/dev/null; then \
        groupdel "$(getent group $USER_GID | cut -d: -f1)" 2>/dev/null || true; \
    fi \
    && groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME -s /usr/bin/zsh \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
