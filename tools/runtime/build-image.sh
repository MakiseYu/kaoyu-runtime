#!/bin/bash
# Run as root on Linux/WSL after qemu-aarch64 binfmt has been registered.
# Usage: build-image.sh BASE_ROOTFS.tar.gz CODEX_PACKAGE.tar.gz OUTPUT_DIRECTORY [RUST_CACHE]
set -Eeuo pipefail
if [ "${1:-}" != --inside ]; then
    [ "$(id -u)" = 0 ] || { echo 'Run as root.' >&2; exit 1; }
    [ $# = 3 ] || [ $# = 4 ] || { echo "Usage: $0 base.tar.gz codex.tar.gz output-dir [rust-cache]" >&2; exit 64; }
    rust_cache=${4:-$(dirname "$0")/../runtime-cache/rust-1.99.1}
    exec unshare --mount --propagation private bash "$0" --inside "$(realpath "$1")" "$(realpath "$2")" "$(realpath -m "$3")" "$(realpath "$rust_cache")"
fi
shift
BASE=$1; CODEX=$2; OUTPUT=$3; RUST_CACHE=$4
POLICY=$(realpath "$(dirname "$0")/../../app/src/main/assets/runtime")
TOOLS=$(realpath "$(dirname "$0")")
python3 "$TOOLS/prepare-rust.py" "$RUST_CACHE" --check
printf '%s  %s\n' 2a02c40189e361a19e7cb07374fe9925f5c4f7db254ae2b9196348c27c286b03 "$BASE" | sha256sum -c -
printf '%s  %s\n' 9d8ecf2d19d3e184877983902d6c85de48b3888dcb72c382a8a0c975845927fb "$CODEX" | sha256sum -c -
IMAGE=$(mktemp -d /var/tmp/kaoyu-image.XXXXXXXX)
echo "Building at $IMAGE (retained for inspection)"
tar -xzf "$BASE" -C "$IMAGE"
mkdir -p "$IMAGE/opt/codex" "$IMAGE/proc" "$IMAGE/dev" "$IMAGE/tmp" "$OUTPUT"
tar -xzf "$CODEX" -C "$IMAGE/opt/codex"
# Install the verified component payloads without rustup or a user-specific toolchain.
# The toolchain is read-only at runtime; Cargo caches and build outputs stay in HOME/workspaces.
while IFS= read -r component; do
    archive="$RUST_CACHE/$component.tar.xz"
    tar -xJf "$archive" -C "$IMAGE/tmp"
    bash "$IMAGE/tmp/$component/install.sh" --prefix=/opt/rust --destdir="$IMAGE" --disable-ldconfig
    rm -rf -- "$IMAGE/tmp/$component"
done < <(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print("\n".join(c["name"]+"-"+p["version"]+"-"+p["target"] for c in p["components"]))' "$TOOLS/rust-toolchain.json")
mkdir -p "$IMAGE/usr/local/bin" "$IMAGE/usr/local/share/kaoyu"
for command in rustc rustdoc cargo rustfmt cargo-fmt clippy-driver cargo-clippy; do
    ln -s "/opt/rust/bin/$command" "$IMAGE/usr/local/bin/$command"
done
cp "$TOOLS/rust-toolchain.json" "$IMAGE/usr/local/share/kaoyu/rust-toolchain.json"
cp "$TOOLS/test-development.sh" "$IMAGE/usr/local/share/kaoyu/test-development.sh"
cp "$TOOLS/debian-packages-v2.tsv" "$IMAGE/tmp/kaoyu-packages.lock"
if [ -f /usr/bin/qemu-aarch64-static ]; then cp /usr/bin/qemu-aarch64-static "$IMAGE/usr/bin/"; fi
cp /etc/resolv.conf "$IMAGE/etc/resolv.conf"
cp /etc/ssl/certs/ca-certificates.crt "$IMAGE/tmp/kaoyu-build-ca.crt"
mount -t proc proc "$IMAGE/proc"
mount --rbind /dev "$IMAGE/dev"
mount --make-rslave "$IMAGE/dev"
cleanup_mounts() { umount -R "$IMAGE/dev" 2>/dev/null || true; umount "$IMAGE/proc" 2>/dev/null || true; }
trap cleanup_mounts EXIT
cat > "$IMAGE/tmp/kaoyu-image-build.sh" <<'BUILD'
#!/bin/bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/bin:/opt/rust/bin:/usr/sbin:/usr/bin:/sbin:/bin
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
sed -i 's|http://deb.debian.org/debian-security|https://security.debian.org/debian-security|g; s|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources
apt-get -o Acquire::Retries=3 -o Acquire::https::CaInfo=/tmp/kaoyu-build-ca.crt update
# The lock includes the original Python/Node/Git tools, build-essential,
# CMake/Ninja/pkg-config, Python development headers, libffi/zlib/SQLite headers,
# zip/unzip/xz/file/patch/sqlite3 and every resolved Debian dependency.
mapfile -t packages < <(awk -F '\t' '{print $1 "=" $2}' /tmp/kaoyu-packages.lock)
apt-get -o Acquire::Retries=3 -o Acquire::https::CaInfo=/tmp/kaoyu-build-ca.crt install -y --no-install-recommends "${packages[@]}"
sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/debian.sources
mkdir -p /usr/local/share/kaoyu /usr/local/libexec /workspace /home/codex /run /tmp
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /usr/local/share/kaoyu/packages.tsv
cmp /tmp/kaoyu-packages.lock /usr/local/share/kaoyu/packages.tsv
/opt/codex/bin/codex --version
test -x /opt/codex/bin/codex-code-mode-host
test -x /opt/codex/codex-resources/bwrap
test -x /opt/codex/codex-path/rg
git --version
python3 --version
node --version
npm --version
gcc --version | head -n 1
g++ --version | head -n 1
rustc --version
cargo --version
rustfmt --version
cargo-clippy --version
# Check ordinary-user builds inside the guest; never compile project code as root.
mkdir -p /tmp/kaoyu-development-home
chown 65534:65534 /tmp/kaoyu-development-home
setpriv --reuid=65534 --regid=65534 --clear-groups env -i HOME=/tmp/kaoyu-development-home \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    /bin/bash /usr/local/share/kaoyu/test-development.sh
rm -rf /tmp/kaoyu-development-home
apt-get clean
find /var/lib/apt/lists -type f -delete
find /var/log -type f -exec truncate -s 0 {} +
# No machine identity, credentials, API keys, accounts or workspaces enter the distributable image.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id /root/.bash_history
BUILD
chmod 755 "$IMAGE/tmp/kaoyu-image-build.sh"
# A registered binfmt interpreter is required because apt invokes many ARM64 subprocesses.
chroot "$IMAGE" /bin/bash /tmp/kaoyu-image-build.sh
mkdir -p "$IMAGE/etc/codex" "$IMAGE/usr/local/bin"
cp "$POLICY/codex-config.toml" "$IMAGE/etc/codex/config.toml"
cp "$POLICY/codex-requirements.toml" "$IMAGE/etc/codex/requirements.toml"
cp "$POLICY/codex.sh" "$IMAGE/usr/local/bin/codex"
chmod 755 "$IMAGE/usr/local/bin/codex"
cleanup_mounts
trap - EXIT
rm -f "$IMAGE/tmp/kaoyu-image-build.sh" "$IMAGE/tmp/kaoyu-build-ca.crt" "$IMAGE/tmp/kaoyu-packages.lock" "$IMAGE/usr/bin/qemu-aarch64-static"
printf 'nameserver 1.1.1.1\n' > "$IMAGE/etc/resolv.conf"
cp "$IMAGE/usr/local/share/kaoyu/packages.tsv" "$OUTPUT/image-packages.tsv"
cp "$TOOLS/rust-toolchain.json" "$OUTPUT/rust-toolchain.json"
UNPACKED=$(du -sb "$IMAGE" | awk '{print $1}')
# USTAR/GNU format keeps runtime extraction narrow and auditable (no PAX/device records).
tar --sort=name --format=gnu --numeric-owner --owner=0 --group=0 --mtime=@1791158400 -cf - -C "$IMAGE" . | gzip -n -9 > "$OUTPUT/debian-arm64.tar.gz"
HASH=$(sha256sum "$OUTPUT/debian-arm64.tar.gz" | awk '{print $1}')
BYTES=$(stat -c %s "$OUTPUT/debian-arm64.tar.gz")
cat > "$OUTPUT/image.properties" <<EOF
format=1
archive=debian-arm64.tar.gz
sha256=$HASH
bytes=$BYTES
unpacked.bytes=$UNPACKED
codex.version=0.163.0
debian.version=12-bookworm
base.sha256=2a02c40189e361a19e7cb07374fe9925f5c4f7db254ae2b9196348c27c286b03
codex.sha256=9d8ecf2d19d3e184877983902d6c85de48b3888dcb72c382a8a0c975845927fb
EOF
cat "$OUTPUT/image.properties"
echo "Built offline image. Preserved staging directory: $IMAGE"
