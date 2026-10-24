# Installing `mac-vm`

`mac-vm` is an aarch64 NixOS guest in VMware Fusion on the work Mac, with
`home`'s Hyprland and j2bar desktop. Before installing anything on the Mac,
check that its management allows Fusion.

## 1. On `home`: publish the flake and bundle j2bar

The VM clones this repository from GitHub, so push the commit with `mac-vm` on
it. The `j2bar` input is the local checkout at `/home/jesse/projects/j2bar`,
which has no remote, and the flake doesn't evaluate without it, so bundle it:

```sh
git -C ~/nix push
git -C ~/projects/j2bar bundle create ~/j2bar.bundle --all
```

Copy `~/j2bar.bundle` to the Mac's `~/Downloads`.

## 2. On the Mac: install Fusion and create the VM

```sh
brew install --cask vmware-fusion        # or download it from Broadcom
curl -L -o ~/Downloads/nixos-aarch64.iso \
  https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-aarch64-linux.iso
```

The ISO must be aarch64; Fusion on Apple silicon doesn't run x86_64 guests.

In Fusion:

1. Choose File → New and drag in `nixos-aarch64.iso`.
2. Pick Linux → Other Linux 6.x kernel 64-bit Arm.
3. Choose Customize Settings and set:
   - Processors & Memory: 16 GB and about 6 cores, fewer than the Mac has.
   - Hard Disk: about 200 GB, NVMe.
   - Display: Accelerate 3D Graphics on.
4. Boot the VM.

## 3. In the installer: open SSH

The installer runs sshd. Give its `nixos` user a password and note the VM's
address:

```sh
passwd
ip -4 addr
```

Then, on the Mac, copy the bundle in:

```sh
scp ~/Downloads/j2bar.bundle nixos@<vm-ip>:
```

## 4. In the installer: partition and install

The checked-in [`hardware-configuration.nix`](../hosts/mac-vm/hardware-configuration.nix)
mounts the partitions by the labels `nixos` and `boot`, so keep those labels.
Check the disk name with `lsblk` first; Fusion's NVMe disk is `nvme0n1`.

j2bar is cloned twice: the installer evaluates the flake from its own
`/home/jesse/projects/j2bar`, and later switches use the installed system's.

```sh
sudo -i
export NIX_CONFIG='experimental-features = nix-command flakes'

parted -s /dev/nvme0n1 -- mklabel gpt \
  mkpart ESP fat32 1MiB 1GiB set 1 esp on \
  mkpart root ext4 1GiB 100%
mkfs.fat -F 32 -n boot /dev/nvme0n1p1
mkfs.ext4 -L nixos /dev/nvme0n1p2
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot

nix-shell -p git --run '
  git clone https://github.com/malinoskj2/nix /mnt/home/jesse/nix
  git clone /home/nixos/j2bar.bundle /mnt/home/jesse/projects/j2bar
  git clone /home/nixos/j2bar.bundle /home/jesse/projects/j2bar
'

cd /mnt/home/jesse/nix
nixos-generate-config --root /mnt --show-hardware-config > hosts/mac-vm/hardware-configuration.nix
nix-shell -p git --run 'git add hosts/mac-vm/hardware-configuration.nix'

nixos-install --flake .#mac-vm
nixos-enter --root /mnt -c 'passwd jesse && chown -R jesse:users /home/jesse'
reboot
```

If `mac-vm` isn't on `main` yet, clone its branch with `-b <branch>`. The
install builds Codex, Orca, j2bar and a few local packages from source, since
no binary cache has them for aarch64.

## 5. First login

Log in as jesse on the console and start the desktop:

```sh
start-hyprland
```

For two monitors, choose View → Use All Displays in Full Screen and then
View → Full Screen. Fusion names the outputs `Virtual-1`, `Virtual-2` and on.
`desktop.monitors` in [`profiles/mac-vm.nix`](../users/jesse/profiles/mac-vm.nix)
makes `Virtual-1` the main monitor and puts `Virtual-2` to its right.

Check that the desktop renders on the GPU. The renderer should be SVGA3D, not
llvmpipe:

```sh
nix shell nixpkgs#mesa-demos -c glxinfo -B | grep -i renderer
```

Fusion has no hardware video decoding, so mpv and the video wallpapers decode
on the CPU.

Commit the generated hardware configuration:

```sh
git -C ~/nix commit -m "Add mac-vm's hardware configuration"
```

From then on, `nh os switch` applies the flake as on the other hosts.
