# =============================================================================
# Standalone Dockerfile: Builds LiveAgent CentOS 7 package from scratch
#
# Uses Ubuntu 24.04 as build environment (provides matching glibc 2.39 pair).
# Verifies on CentOS 7.
#
# Usage:
#   docker build -t liveagent-centos7 .
#
#   # Extract the package
#   docker create --name tmp liveagent-centos7
#   docker cp tmp:/output/liveagent-centos7-x86_64.tar.gz .
#   docker rm tmp
# =============================================================================

FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
    curl \
    ca-certificates \
    file \
    patchelf \
    squashfs-tools \
    binutils \
    libwayland-client0 libwayland-cursor0 libwayland-egl1 libwayland-server0 \
    libxkbcommon0 \
    libfribidi0 libharfbuzz0b libfontconfig1 libfreetype6 libexpat1 \
    libdrm2 libxcb1 libx11-6 libx11-xcb1 libgbm1 libegl1 libgl1 \
    && rm -rf /var/lib/apt/lists/*

ARG APPIMAGE_URL=https://github.com/Stack-Cairn/LiveAgent/releases/download/v1.3.0/LiveAgent-v1.3.0-Linux-x86_64.AppImage

WORKDIR /workspace

# --- Download and extract AppImage ---
RUN curl -fSL -o LiveAgent.AppImage "$APPIMAGE_URL" && \
    chmod +x LiveAgent.AppImage && \
    ./LiveAgent.AppImage --appimage-extract > /dev/null 2>&1 || true && \
    mv squashfs-root AppDir

# --- Create bundle and collect ALL dependencies ---
RUN rm -rf bundle && mkdir -p bundle && cp -a AppDir/* bundle/ && \
    mkdir -p bundle/lib64 && \
    # Copy ALL bundled libs from AppDir to lib64 for --library-path
    for dir in bundle/usr/lib bundle/usr/lib64 bundle/lib bundle/lib64; do \
        if [ -d "$dir" ]; then \
            find "$dir" -name "*.so*" \( -type f -o -type l \) | while read -r lib; do \
                bn=$(basename "$lib"); \
                [ -e "bundle/lib64/$bn" ] || cp -aL "$lib" bundle/lib64/ 2>/dev/null || true; \
            done; \
        fi; \
    done && \
    # Full recursive dependency walk from ALL bundled ELF files
    find bundle -type f | while read -r f; do \
        file "$f" 2>/dev/null | grep -q ELF && ldd "$f" 2>/dev/null | awk '/=>/ {print $3}'; \
    done | sort -u > /tmp/all_deps.txt && \
    prev_count=0; \
    while true; do \
        count=$(wc -l < /tmp/all_deps.txt); \
        [ "$count" = "$prev_count" ] && break; \
        prev_count=$count; \
        while IFS= read -r lib; do \
            [ -z "$lib" ] && continue; \
            echo "$lib" | grep -q "^/" || continue; \
            bn=$(basename "$lib"); \
            for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64 /usr/lib; do \
                [ -e "$d/$bn" ] || continue; \
                ldd "$d/$bn" 2>/dev/null | awk '/=>/ {print $3}'; \
                break; \
            done; \
        done < /tmp/all_deps.txt | sort -u >> /tmp/all_deps.txt; \
        sort -u /tmp/all_deps.txt -o /tmp/all_deps.txt; \
    done && \
    # Copy ONLY system libs not already in bundle
    while IFS= read -r lib; do \
        [ -z "$lib" ] && continue; \
        echo "$lib" | grep -q "^/" || continue; \
        bn=$(basename "$lib"); \
        [ -e "bundle/lib64/$bn" ] && continue; \
        echo "$bn" | grep -qE "^libc\.|libm\.|libpthread\.|libdl\.|libresolv\.|librt\.|libnss_|libgcc_s|libstdc\+\+|ld-linux" && continue; \
        for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /lib64 /usr/lib; do \
            [ -e "$d/$bn" ] || continue; \
            dir=$(dirname "$d/$bn"); \
            base=$(echo "$bn" | sed "s/\.so\..*/.so/"); \
            for v in "$dir"/"$base"*; do \
                [ -e "$v" ] || continue; \
                cp -aL "$v" bundle/lib64/ 2>/dev/null || true; \
            done; \
            break; \
        done; \
    done < /tmp/all_deps.txt && \
    # Bundle Ubuntu 24.04 glibc 2.39
    cp -L /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libc.so.6 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libm.so.6 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libpthread.so.0 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libdl.so.2 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libresolv.so.2 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/librt.so.1 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libnss_files.so.2 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libnss_dns.so.2 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libgcc_s.so.1 bundle/lib64/ && \
    cp -L /lib/x86_64-linux-gnu/libstdc++.so.6 bundle/lib64/ && \
    # Create WebKit process symlinks
    mkdir -p bundle/lib/x86_64-linux-gnu/webkit2gtk-4.1 && \
    ln -sf ../../../usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess \
        bundle/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitNetworkProcess && \
    ln -sf ../../../usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess \
        bundle/lib/x86_64-linux-gnu/webkit2gtk-4.1/WebKitWebProcess && \
    # Copy injected-bundle (must be real file, not symlink)
    mkdir -p bundle/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle && \
    cp -a bundle/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so \
        bundle/lib/x86_64-linux-gnu/webkit2gtk-4.1/injected-bundle/ && \
    echo "=== Bundle lib64 contents ===" && \
    ls bundle/lib64/ | wc -l && echo "libraries"

# --- Patch ELF binaries ---
RUN BUNDLE_DIR=/opt/liveagent && \
    find bundle -type f | while read -r f; do \
        echo "$f" | grep -q "ld-linux-x86-64.so.2" && continue; \
        file "$f" 2>/dev/null | grep -q ELF || continue; \
        patchelf --set-interpreter "$BUNDLE_DIR/lib64/ld-linux-x86-64.so.2" "$f" 2>/dev/null || true; \
        patchelf --set-rpath "$BUNDLE_DIR/lib64:$BUNDLE_DIR/lib:$BUNDLE_DIR/lib/x86_64-linux-gnu:$BUNDLE_DIR/usr/lib:$BUNDLE_DIR/usr/lib64:$BUNDLE_DIR/usr/lib/x86_64-linux-gnu" "$f" 2>/dev/null || true; \
    done

# --- Create launcher ---
RUN cat > /workspace/bundle/liveagent-centos7.sh <<'LAUNCHER'
#!/usr/bin/env bash
# LiveAgent CentOS 7 Launcher
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${SCRIPT_DIR}"

export LC_ALL=${LC_ALL:-C}
export LANG=${LANG:-C}
export GTK_PATH="${BUNDLE}/usr/lib/x86_64-linux-gnu/gtk-3.0"
export GDK_BACKEND=x11
export LD_LIBRARY_PATH="${BUNDLE}/lib64:${BUNDLE}/lib:${BUNDLE}/lib/x86_64-linux-gnu:${BUNDLE}/usr/lib:${BUNDLE}/usr/lib64:${BUNDLE}/usr/lib/x86_64-linux-gnu"
export LIBGL_ALWAYS_SOFTWARE=1
export WEBKIT_DISABLE_COMPOSITING_MODE=1

cd "${BUNDLE}"

exec "${BUNDLE}/lib64/ld-linux-x86-64.so.2" \
    --library-path "${LD_LIBRARY_PATH}" \
    "${BUNDLE}/usr/bin/liveagent" "$@"
LAUNCHER
RUN chmod +x /workspace/bundle/liveagent-centos7.sh

# --- Package ---
RUN cd /workspace/bundle && \
    tar -czf /output/liveagent-centos7-x86_64.tar.gz . && \
    sha256sum /output/liveagent-centos7-x86_64.tar.gz > /output/liveagent-centos7-x86_64.tar.gz.sha256 && \
    echo "=== Package created ===" && \
    ls -lh /output/liveagent-centos7-x86_64.tar.gz && \
    echo "=== ld-linux verification ===" && \
    ls -la lib64/ld-linux-x86-64.so.2

# =============================================================================
# Verify stage: test on actual CentOS 7
# =============================================================================
FROM centos:7 AS verify

RUN yum install -y -q tar gzip && yum clean all

COPY --from=builder /output/liveagent-centos7-x86_64.tar.gz /tmp/

RUN echo "=== CentOS 7 Compatibility Verification ===" && \
    echo "OS: $(cat /etc/centos-release)" && \
    echo "System glibc: $(/lib64/libc.so.6 2>&1 | head -1)" && \
    echo "" && \
    mkdir -p /opt/liveagent && \
    tar -xzf /tmp/liveagent-centos7-x86_64.tar.gz -C /opt/liveagent && \
    echo "=== Testing bundled ld-linux ===" && \
    /opt/liveagent/lib64/ld-linux-x86-64.so.2 --version 2>&1 | head -1 && \
    echo "=== Verification Complete ==="

CMD ["/opt/liveagent/liveagent-centos7.sh"]
