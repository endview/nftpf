#!/usr/bin/env bash
# Run the real Jool test under an installed distro kernel, including on WSL hosts.
set -euo pipefail
script=$(realpath "${1:-./nftpf.sh}")
repo=$(dirname "$script")
kernel=${NFTPF_TEST_KERNEL:-$(basename "$(find /boot -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -1)" | sed 's/^vmlinuz-//')}
[[ -f "/boot/vmlinuz-$kernel" ]] || { echo 'install a distro kernel image and its Jool DKMS module first' >&2; exit 1; }
for dependency in qemu-system-x86_64 busybox cpio gzip ldd modprobe depmod xz python3; do command -v "$dependency" >/dev/null; done
modprobe --set-version "$kernel" --show-depends jool >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root"/{bin,usr/bin,proc,sys,dev,run,tmp,work,etc,lib/modules}
ln -s usr/bin "$root/sbin"
ln -s bin "$root/usr/sbin"
cp -L "$(command -v busybox)" "$root/usr/bin/busybox"
busybox --install -s "$root/bin"

copy_libraries() {
    local binary=$1 library
    while IFS= read -r library; do
        [[ -f "$library" ]] || continue
        mkdir -p "$root$(dirname "$library")"
        cp -L "$library" "$root$library"
    done < <(ldd "$binary" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}')
}
for program in bash nft ip jool modprobe sysctl stat awk grep sed head sort cut tr realpath tar mktemp chmod cp mv rm cat date unshare mount umount flock python3; do
    binary=$(command -v "$program")
    cp -L "$binary" "$root/usr/bin/$program"
    copy_libraries "$binary"
done
pyversion=$(python3 -c 'import sys;print("%s.%s" % sys.version_info[:2])')
mkdir -p "$root/usr/lib"
cp -a "/usr/lib/python$pyversion" "$root/usr/lib/"
while IFS= read -r extension; do copy_libraries "$extension"; done < <(find "/usr/lib/python$pyversion/lib-dynload" -name '*.so')

mkdir -p "$root/lib/modules/$kernel"
for metadata in /lib/modules/"$kernel"/modules.*; do [[ ! -f "$metadata" ]] || cp "$metadata" "$root/lib/modules/$kernel/"; done
while IFS= read -r module; do
    mkdir -p "$root$(dirname "$module")"
    if [[ "$module" == *.xz ]]; then
        xz -dc "$module" > "$root${module%.xz}"
    else
        cp "$module" "$root$module"
    fi
done < <(
    {
        for name in jool veth crc32c_generic crc32c_intel nf_tables nft_nat nft_chain_nat nft_masq nft_counter nft_ct nft_set_hash nft_set_rbtree nft_set_pipapo; do
            modprobe --set-version "$kernel" --show-depends "$name" 2>/dev/null || true
        done
    } | awk '$1 == "insmod" {print $2}' | sort -u
)
depmod -b "$root" "$kernel"
cp "$script" "$root/work/nftpf.sh"
cp "$repo/tests/jool-integration.sh" "$root/work/jool-integration.sh"
cat > "$root/init" <<'INIT'
#!/usr/bin/bash
export PATH=/usr/bin:/bin
export PYTHONHOME=/usr
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
ln -s /proc/self/fd /dev/fd
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts
modprobe nf_tables
modprobe nft_chain_nat
modprobe nft_masq
modprobe veth
echo 'NFTPF_JOOL_TEST_BEGIN'
if bash /work/jool-integration.sh /work/nftpf.sh; then
    echo 'NFTPF_JOOL_TEST_PASS'
else
    echo 'NFTPF_JOOL_TEST_FAIL'
    dmesg | tail -20
fi
sync
poweroff -f
INIT
chmod +x "$root/init"
(cd "$root" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -1) > "$work/initrd.gz"
log=${NFTPF_TEST_LOG:-$work/qemu.log}
timeout 180 qemu-system-x86_64 -machine accel=tcg -m 768 -smp 2 -nographic -no-reboot \
    -kernel "/boot/vmlinuz-$kernel" -initrd "$work/initrd.gz" \
    -append 'console=ttyS0 panic=-1 quiet' -nic none > "$log" 2>&1 || true
cat "$log"
grep -q '^NFTPF_JOOL_TEST_PASS' "$log"
