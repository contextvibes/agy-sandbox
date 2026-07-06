# Interactive NixOS Installation Guide inside Virtualization.framework

Once the NixOS GUI console window opens, you will be at the NixOS root shell installer prompt. Follow these exact steps to partition, configure, and install NixOS onto your persistent 32GB virtual hard drive (`/dev/vdb`).

---

## Step 1: Partition and Format the Virtual Drive (`/dev/vdb`)

Run the following commands inside the VM terminal to create a standard GPT partition table with a 512MB UEFI ESP boot partition and an ext4 root partition:

```bash
# 1. Initialize GPT partition table
parted /dev/vdb -- mktable gpt

# 2. Create the EFI boot partition (ESP)
parted /dev/vdb -- mkpart ESP fat32 1MiB 512MiB
parted /dev/vdb -- set 1 esp on

# 3. Create the main root partition
parted /dev/vdb -- mkpart primary ext4 512MiB 100%

# 4. Format the EFI partition as FAT32
mkfs.vfat -F 32 -n boot /dev/vdb1

# 5. Format the root partition as ext4
mkfs.ext4 -L nixos /dev/vdb2
```

---

## Step 2: Mount the Filesystems

Mount your new partitions under the standard `/mnt` install root:

```bash
# 1. Mount the root filesystem
mount /dev/disk/by-label/nixos /mnt

# 2. Create and mount the boot directory
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot /mnt/boot
```

---

## Step 3: Generate Base Configuration and Fetch Custom Template

Next, generate the hardware configuration and pull our custom template from the host macOS:

```bash
# 1. Generate hardware profile
nixos-generate-config --root /mnt

# 2. Copy the custom configuration and flake files from the VirtioFS mount:
cp /tmp/shared/guest/nixos/configuration.nix /mnt/etc/nixos/
cp /tmp/shared/guest/nixos/flake.nix /mnt/etc/nixos/
```

---

## Step 4: Install NixOS

Run the installer. It will automatically download all required packages and set up the GRUB/systemd-boot environment inside `/dev/vdb`:

```bash
nixos-install --flake /mnt/etc/nixos#antigravity-nixos --no-root-passwd
```

Once the installation displays `Finished successfully!`, you can shut down the VM:
```bash
poweroff
```

Then we can boot directly from your persistent guest image `nixos_guest.img`!
