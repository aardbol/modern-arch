#!/usr/bin/env bash
# 01-disk.sh — destructive disk preparation for modern-arch-setup.
#
# Wipes ONE whole disk and builds:
#   GPT
#   ├─ p1  ESP (FAT32)                     -> /boot
#   └─ p2  LUKS2 (aes-xts-plain64/512)     -> /dev/mapper/<mapper> -> btrfs
#        @        -> /
#        @home    -> /home
#        @swap    -> /swap
#        @games   -> /opt/games   (optional)
#
# Everything is mounted under MOUNT_ROOT (default /mnt) for archinstall's
# "pre_mounted_config" mode. No package installation happens here.
#
# Run from the Arch ISO:  ./scripts/01-disk.sh -D /dev/nvme0n1
# Plan only:             ./scripts/01-disk.sh -D /dev/nvme0n1 -d

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ESP_SIZE="${ESP_SIZE:-1G}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt}"
MAPPER="${MAPPER:-root}"
BTRFS_LABEL="${BTRFS_LABEL:-arch}"
BTRFS_OPTS="${BTRFS_OPTS:-noatime,compress=zstd:3,ssd,space_cache=v2}"
ESP_OPTS="${ESP_OPTS:-defaults,fmask=0077,dmask=0077}"
ALLOW_DISCARDS="${ALLOW_DISCARDS:-1}"

DISK=''
WITH_GAMES='auto'
DRY_RUN=0
HEADER_BACKUP=''

usage() {
	cat <<'EOF'
Usage: 01-disk.sh --disk DEVICE [options]

WIPES the given disk and creates: ESP + LUKS2(btrfs: @, @home, @swap [, @games]).

Options:
  -D, --disk DEV      whole disk to erase (e.g. /dev/nvme0n1). Asked if omitted.
  -g, --games         create the @games subvolume (mounted at /opt/games)
  -G, --no-games      do not create @games
  -s, --esp-size SIZE ESP size passed to sgdisk (default: 1G)
  -m, --mount-root DIR where the new system is mounted (default: /mnt)
  -M, --mapper NAME   dm-crypt mapper name (default: root)
  -l, --label NAME    btrfs filesystem label (default: arch)
  -b, --header-backup DIR save a LUKS2 header backup into DIR (root-only file)
  -x, --no-discard    do not pass --allow-discards to cryptsetup
  -d, --dry-run       print the plan and exit without touching anything
  -h, --help          this help

Environment overrides: BTRFS_OPTS, ESP_OPTS, ESP_SIZE, MOUNT_ROOT, MAPPER,
BTRFS_LABEL, ALLOW_DISCARDS=0.

This script does NOT partition by itself if anything from the disk is in use;
it refuses and asks you to unmount/close first.
EOF
}

parse_args() {
	while (( $# )); do
		case $1 in
			-D|--disk)          DISK=${2:?-D/--disk needs a value}; shift 2 ;;
			-g|--games)         WITH_GAMES=1; shift ;;
			-G|--no-games)      WITH_GAMES=0; shift ;;
			-s|--esp-size)      ESP_SIZE=${2:?-s/--esp-size needs a value}; shift 2 ;;
			-m|--mount-root)    MOUNT_ROOT=${2:?-m/--mount-root needs a value}; shift 2 ;;
			-M|--mapper)        MAPPER=${2:?-M/--mapper needs a value}; shift 2 ;;
			-l|--label)         BTRFS_LABEL=${2:?-l/--label needs a value}; shift 2 ;;
			-b|--header-backup) HEADER_BACKUP=${2:?-b/--header-backup needs a value}; shift 2 ;;
			-x|--no-discard)    ALLOW_DISCARDS=0; shift ;;
			-d|--dry-run)       DRY_RUN=1; shift ;;
			-h|--help)          usage; exit 0 ;;
			*)                  usage >&2; die "unknown argument: $1" ;;
		esac
	done
}

live_disk() {
	local src
	src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
	[[ -n $src ]] || return 0
	lsblk -no PKNAME "$src" 2>/dev/null | head -n1 | sed 's|^|/dev/|'
}

pick_disk() {
	[[ -n $DISK ]] && return

	local live
	live=$(live_disk)

	log "Available whole disks:"
	lsblk -dpno NAME,SIZE,TYPE,RM,MODEL | awk '$3 == "disk"'
	[[ -n $live ]] && warn "the running live ISO is on $live — it will be rejected"
	echo
	DISK=$(ask "Whole disk to ERASE (e.g. /dev/nvme0n1): ")
	[[ $DISK == /dev/* ]] || DISK="/dev/$DISK"

	[[ -n $DISK ]] || die "no disk given"
	[[ -n $live && $DISK == "$live" ]] && die "$DISK holds the running live ISO"
}

check_disk() {
	[[ -b $DISK ]] || die "$DISK is not a block device"
	[[ $(lsblk -dno TYPE -- "$DISK") == disk ]] || die "$DISK is not a whole disk"

	local size_bytes
	size_bytes=$(lsblk -bdno SIZE -- "$DISK")
	(( size_bytes >= 16 * 1024 * 1024 * 1024 )) || \
		die "$DISK is smaller than 16 GiB; this layout is not meant for it"

	local live
	live=$(live_disk)
	[[ -n $live && $(readlink -f "$DISK") == "$(readlink -f "$live")" ]] && \
		die "$DISK holds the running live ISO"

	if lsblk -nr -o MOUNTPOINTS -- "$DISK" | grep -qvE '^[[:space:]]*$'; then
		lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS -- "$DISK" >&2
		die "$DISK has mounted filesystems; unmount them first"
	fi

	if lsblk -nr -o TYPE -- "$DISK" | grep -qx 'crypt'; then
		die "$DISK has an active dm-crypt mapping; close it first (cryptsetup close ...)"
	fi

	if swapon --show=NAME --noheadings 2>/dev/null | tr -d ' ' | grep -qE "^${DISK}(p?[0-9]+)?$"; then
		die "$DISK or one of its partitions is active swap; swapoff it first"
	fi

	if [[ $(lsblk -dno RM -- "$DISK") == 1 ]]; then
		warn "$DISK is removable media — double-check that it is the right device"
	fi
}

check_mountpoint() {
	[[ $MOUNT_ROOT == / ]] && die "MOUNT_ROOT must not be / (refusing to mount the install over the live system)"
	if mountpoint -q "$MOUNT_ROOT"; then
		die "$MOUNT_ROOT is already a mountpoint; unmount it first"
	fi
	if grep -qE "[[:space:]]${MOUNT_ROOT%/}/" /proc/mounts; then
		die "something is mounted below $MOUNT_ROOT; unmount it first (umount -R $MOUNT_ROOT)"
	fi
	if cryptsetup status "$MAPPER" >/dev/null 2>&1; then
		die "a mapper named '$MAPPER' is already active; close it or pass --mapper"
	fi
}

print_plan() {
	local suffix esp part discard
	suffix=$(part_suffix "$DISK")
	esp="${DISK}${suffix}1"
	part="${DISK}${suffix}2"
	discard=''
	[[ $ALLOW_DISCARDS == 1 ]] && discard=' --allow-discards'

	cat <<EOF
Plan (nothing has been changed):

  wipefs -a -f $DISK
  sgdisk --zap-all $DISK
  sgdisk --new=1:0:+$ESP_SIZE --typecode=1:ef00 --change-name=1:ESP $DISK
  sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot $DISK
  mkfs.fat -F 32 -n ESP $esp
  cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id $part
  cryptsetup open$discard $part $MAPPER
  mkfs.btrfs -f -L $BTRFS_LABEL /dev/mapper/$MAPPER
  btrfs subvolume create { @, @home, @swap$( ((WITH_GAMES == 1)) && printf ', @games') }
  mount -o subvol=@,$BTRFS_OPTS /dev/mapper/$MAPPER $MOUNT_ROOT
  mount -o subvol=@home,$BTRFS_OPTS ... $MOUNT_ROOT/home
  mount -o subvol=@swap,noatime ... $MOUNT_ROOT/swap
  mount $esp $MOUNT_ROOT/boot

  ALL DATA ON $DISK WILL BE LOST.
EOF
}

part_suffix() {
	# nvme0n1 -> p, mmcblk0 -> p, sda -> empty
	if [[ $1 =~ [0-9]$ ]]; then printf 'p'; else printf ''; fi
}

partition_disk() {
	local esp=$1 part=$2

	wipefs -a -f "$DISK"
	sgdisk --zap-all "$DISK"
	sgdisk --new=1:0:+"$ESP_SIZE" --typecode=1:ef00 --change-name=1:ESP "$DISK"
	sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot "$DISK"
	sgdisk --print "$DISK"

	partprobe "$DISK" || true
	udevadm settle

	local i
	for (( i = 0; i < 20; i++ )); do
		[[ -b $esp && -b $part ]] && break
		sleep 0.5
		udevadm settle
	done
	[[ -b $esp && -b $part ]] || die "partition devices did not appear ($esp / $part)"
}

format_esp() {
	mkfs.fat -F 32 -n ESP "$1"
}

format_luks() {
	local part=$1
	cryptsetup luksFormat \
		--type luks2 \
		--cipher aes-xts-plain64 \
		--key-size 512 \
		--hash sha512 \
		--pbkdf argon2id \
		--label cryptroot \
		"$part"

	if [[ -n $HEADER_BACKUP ]]; then
		mkdir -p "$HEADER_BACKUP"
		local out="$HEADER_BACKUP/$(basename "$part")-luks2-header.img"
		cryptsetup luksHeaderBackup "$part" --header-backup-file "$out"
		chmod 600 "$out"
		ok "LUKS header backed up to $out (keep it somewhere safe, it unlocks the disk)"
	fi

	local discards=()
	[[ $ALLOW_DISCARDS == 1 ]] && discards=(--allow-discards)
	cryptsetup open "${discards[@]}" "$part" "$MAPPER"
	[[ -b /dev/mapper/$MAPPER ]] || die "/dev/mapper/$MAPPER did not appear"
}

format_btrfs() {
	mkfs.btrfs -f -L "$BTRFS_LABEL" "/dev/mapper/$MAPPER"
}

create_subvolumes() {
	mkdir -p "$MOUNT_ROOT"
	mount -t btrfs -o "$BTRFS_OPTS" "/dev/mapper/$MAPPER" "$MOUNT_ROOT"

	btrfs subvolume create "$MOUNT_ROOT/@"
	btrfs subvolume create "$MOUNT_ROOT/@home"
	btrfs subvolume create "$MOUNT_ROOT/@swap"
	if (( WITH_GAMES )); then
		btrfs subvolume create "$MOUNT_ROOT/@games"
	fi

	# Swapfile must never be COW+compressed; nocow is inherited by new files.
	chattr +C "$MOUNT_ROOT/@swap"

	btrfs subvolume list "$MOUNT_ROOT"
	umount "$MOUNT_ROOT"
}

mount_target() {
	mkdir -p "$MOUNT_ROOT"
	mount -o "subvol=@,$BTRFS_OPTS" "/dev/mapper/$MAPPER" "$MOUNT_ROOT"

	mkdir -p "$MOUNT_ROOT/home" "$MOUNT_ROOT/swap" "$MOUNT_ROOT/boot"
	mount -o "subvol=@home,$BTRFS_OPTS" "/dev/mapper/$MAPPER" "$MOUNT_ROOT/home"
	mount -o "subvol=@swap,noatime" "/dev/mapper/$MAPPER" "$MOUNT_ROOT/swap"

	if (( WITH_GAMES )); then
		mkdir -p "$MOUNT_ROOT/opt/games"
		mount -o "subvol=@games,$BTRFS_OPTS" "/dev/mapper/$MAPPER" "$MOUNT_ROOT/opt/games"
	fi

	mount -o "$ESP_OPTS" "$1" "$MOUNT_ROOT/boot"
}

verify_and_report() {
	log "Result"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS -- "$DISK"
	echo
	cryptsetup status "$MAPPER" | sed 's/^/  /'
	echo
	btrfs subvolume list "$MOUNT_ROOT" | sed 's/^/  /'
	echo
	findmnt -R "$MOUNT_ROOT" -o TARGET,SOURCE,FSTYPE,OPTIONS | sed 's/^/  /'

	echo
	ok "disk ready"
	cat <<EOF

Next:
  scripts/02-archinstall.sh   (archinstall pre-mount config, "mountpoint": "$MOUNT_ROOT")
  The initramfs cryptdevice= and resume= parameters are written by
  scripts/03-finalize.sh — do NOT reboot before running it.

To start over:
  umount -R $MOUNT_ROOT && cryptsetup close $MAPPER
EOF
}

main() {
	parse_args "$@"
	[[ -n $DISK && $DISK != /dev/* ]] && DISK="/dev/$DISK"
	require_root
	require_cmds lsblk findmnt mountpoint wipefs sgdisk partprobe udevadm \
		mkfs.fat cryptsetup mkfs.btrfs btrfs chattr mount umount blkid

	if [[ ! -d /run/archiso ]]; then
		warn "this does not look like the Arch ISO (no /run/archiso)"
	fi

	pick_disk
	check_disk
	check_mountpoint

	local suffix esp part
	suffix=$(part_suffix "$DISK")
	esp="${DISK}${suffix}1"
	part="${DISK}${suffix}2"

	log "Target: $DISK"
	lsblk -o NAME,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINTS -- "$DISK"
	echo

	if [[ $WITH_GAMES == auto ]]; then
		WITH_GAMES=0
		if (( ! DRY_RUN )) && [[ $(ask "Create the @games subvolume (mounted at /opt/games)? [y/N] ") == [yY]* ]]; then
			WITH_GAMES=1
		fi
	fi

	if (( DRY_RUN )); then
		print_plan
		exit 0
	fi

	echo
	warn "This will DESTROY every partition and filesystem on $DISK."
	confirm_phrase "Type the device path ($DISK) to continue: " "$DISK"
	confirm_phrase "Type ERASE to confirm again: " 'ERASE'

	log "Wiping and partitioning $DISK"
	partition_disk "$esp" "$part"

	log "Creating ESP"
	format_esp "$esp"

	log "Creating LUKS2 container on $part (cryptsetup will ask for a passphrase twice)"
	format_luks "$part"

	log "Creating btrfs on /dev/mapper/$MAPPER"
	format_btrfs

	log "Creating subvolumes"
	create_subvolumes

	log "Mounting under $MOUNT_ROOT"
	mount_target "$esp"

	verify_and_report
}

main "$@"