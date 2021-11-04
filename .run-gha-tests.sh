#!/bin/bash
set -eux
export OPAMYES=true

sudo wget https://github.com/opencontainers/runc/releases/download/v1.0.2/runc.amd64 -O /usr/local/bin/runc
sudo chmod a+x /usr/local/bin/runc

sudo sh -c "cat > /usr/local/bin/uname" << "EOF"
#!/bin/sh

if test "$1" = '-r'; then
  echo '5.08.0-6-amd64'
else
  /usr/bin/uname $@
fi
EOF
sudo chmod a+x /usr/local/bin/uname

dd if=/dev/zero of=/tmp/zfs.img bs=100M count=50
ZFS_LOOP=$(sudo losetup -f)
sudo losetup -P "$ZFS_LOOP" /tmp/zfs.img
sudo zpool create zfs "$ZFS_LOOP"

dd if=/dev/zero of=/tmp/btrfs.img bs=100M count=50
BTRFS_LOOP=$(sudo losetup -f)
sudo losetup -P "$BTRFS_LOOP" /tmp/btrfs.img
sudo mkfs.btrfs -f "$BTRFS_LOOP"
sudo mkdir /btrfs
sudo mount -t btrfs "$BTRFS_LOOP" /btrfs
sudo chown "$(whoami)" /btrfs

#opam exec -- make
_build/install/default/bin/obuilder
_build/install/default/bin/obuilder healthcheck --store=btrfs:/btrfs
_build/install/default/bin/obuilder healthcheck --store=zfs:zfs
_build/default/stress/stress.exe btrfs:/btrfs
_build/default/stress/stress.exe zfs:zfs

# Populate the caches from our own GitHub Actions cache
btrfs subvolume create /btrfs/cache/c-opam-archives
cp -r ~/.opam/download-cache/* /btrfs/cache/c-opam-archives/
sudo chown -R 1000:1000 /btrfs/cache/c-opam-archives

sudo zfs create zfs/cache/c-opam-archives
sudo cp -r ~/.opam/download-cache/* /zfs/cache/c-opam-archives/
sudo chown -R 1000:1000 /zfs/cache/c-opam-archives
sudo zfs snapshot zfs/cache/c-opam-archives@snap

_build/install/default/obuilder build -f example.spec . --store=btrfs:/btrfs
_build/install/default/obuilder build -f example.spec . --store=zfs:zfs