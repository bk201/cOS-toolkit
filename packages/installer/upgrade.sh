#!/bin/bash
set -e

CHANNEL_UPGRADES="${CHANNEL_UPGRADES:-true}"

# 1. Identify active/passive partition
# 2. Install upgrade in passive partition
# 3. Invert partition labels

find_partitions() {
    STATE=$(blkid -L COS_STATE || true)
    if [ -z "$STATE" ]; then
        echo "State partition cannot be found"
        exit 1
    fi

    PERSISTENT=$(blkid -L COS_PERSISTENT || true)
    if [ -z "$PERSISTENT" ]; then
        echo "Persistent partition cannot be found"
        exit 1
    fi

    COS_ACTIVE=$(blkid -L COS_ACTIVE || true)
    if [ -n "$COS_ACTIVE" ]; then
        CURRENT=active.img
    fi

    COS_PASSIVE=$(blkid -L COS_PASSIVE || true)
    if [ -n "$COS_PASSIVE" ]; then
        CURRENT=passive.img
    fi

    if [ -z "$CURRENT" ]; then
        # We booted from an ISO or some else medium. We assume we want to fixup the current label
        read -p "Could not determine current partition. Do you want to overwrite your current active partition? (CURRENT=active.img) [y/N] : " -n 1 -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]
        then
            [[ "$0" = "$BASH_SOURCE" ]] && exit 1 || return 1 # handle exits from shell or function but don't exit interactive shell
        fi
        CURRENT=active.img
        echo
    fi

    echo "-> Upgrade target: $CURRENT"
}

find_recovery() {
    RECOVERY=$(blkid -L COS_RECOVERY || true)
    if [ -z "$RECOVERY" ]; then
        echo "COS_RECOVERY partition cannot be found"
        exit 1
    fi
}

# cos-upgrade-image: system/cos
find_upgrade_channel() {
    if [ -e "/etc/cos-upgrade-image" ]; then
        source /etc/cos-upgrade-image
    fi

    if [ -n "$IMAGE" ]; then
        UPGRADE_IMAGE=$IMAGE
        echo "Upgrading to image $UPGRADE_IMAGE"
    fi

    if [ -z "$UPGRADE_IMAGE" ]; then
        UPGRADE_IMAGE="system/cos"
    fi

    if [ -n "$UPGRADE_RECOVERY" ] && [ $UPGRADE_RECOVERY == true ] && [ -n "$RECOVERY_IMAGE" ]; then
        UPGRADE_IMAGE=$RECOVERY_IMAGE
    fi
}

is_squashfs() {
    if [ -e "${STATEDIR}/cOS/recovery.squashfs" ]; then
        return 0
    else
        return 1
    fi
}

recovery_boot() {
    cmdline="$(cat /proc/cmdline)"
    if echo $cmdline | grep -q "COS_RECOVERY" || echo $cmdline | grep -q "COS_SYSTEM"; then
        return 0
    else
        return 1
    fi
}

prepare_target() {
    mkdir -p ${STATEDIR}/cOS || true
    rm -rf ${STATEDIR}/cOS/transition.img || true
    dd if=/dev/zero of=${STATEDIR}/cOS/transition.img bs=1M count=3240
    mkfs.ext2 ${STATEDIR}/cOS/transition.img
    mount -t ext2 -o loop ${STATEDIR}/cOS/transition.img $TARGET
}

prepare_squashfs_target() {
    rm -rf $TARGET || true
    TARGET=${STATEDIR}/tmp/target
    mkdir -p $TARGET
}

mount_state() {
    STATEDIR=/run/initramfs/state
    mkdir -p $STATEDIR
    mount ${STATE} ${STATEDIR}
}

mount_image() {
    STATEDIR=/run/initramfs/isoscan
    TARGET=/tmp/upgrade

    mkdir -p $TARGET || true

    if [ -d "$STATEDIR" ]; then
        if recovery_boot; then
            mount_state
        else
            mount -o remount,rw ${STATE} ${STATEDIR}
        fi
    else
        mount_state
    fi

    prepare_target
}

mount_recovery() {
    STATEDIR=/tmp/recovery
    TARGET=/tmp/upgrade

    mkdir -p $TARGET || true
    mkdir -p $STATEDIR || true
    mount $RECOVERY $STATEDIR
    if is_squashfs; then
        echo "Preparing squashfs target"
        prepare_squashfs_target
    else
        echo "Preparing image target"
        prepare_target
    fi
}

upgrade() {
    ensure_dir_structure

    temp_upgrade=$STATEDIR/tmp/upgrade
    rm -rf $temp_upgrade || true
    mkdir -p $temp_upgrade

    # FIXME: XDG_RUNTIME_DIR is for containerd, by default that points to /run/user/<uid>
    # which might not be sufficient to unpack images. Use /usr/local/tmp until we get a separate partition
    # for the state
    # FIXME: Define default /var/tmp as tmpdir_base in default luet config file
    export XDG_RUNTIME_DIR=$temp_upgrade
    export TMPDIR=$temp_upgrade

    if [ -n "$CHANNEL_UPGRADES" ] && [ "$CHANNEL_UPGRADES" == true ]; then
        if [ -z "$VERIFY" ]; then
          args="--plugin image-mtree-check"
        fi
        luet install $args --system-target $TARGET --system-engine memory -y $UPGRADE_IMAGE
        luet cleanup
    else
        args=""
        if [ -z "$VERIFY" ]; then
          args="--plugin image-mtree-check"
        fi
        luet util unpack $args $UPGRADE_IMAGE /usr/local/tmp/rootfs
        rsync -aqzAX --exclude='mnt' --exclude='proc' --exclude='sys' --exclude='dev' --exclude='tmp' /usr/local/tmp/rootfs/ $TARGET
        rm -rf /usr/local/tmp/rootfs
    fi

    SELinux_relabel

    rm -rf $temp_upgrade
    umount $TARGET || true
}

SELinux_relabel()
{
    if which setfiles > /dev/null && [ -e ${TARGET}/etc/selinux/targeted/contexts/files/file_contexts ]; then
        setfiles -r ${TARGET} ${TARGET}/etc/selinux/targeted/contexts/files/file_contexts ${TARGET}
    fi
}

switch_active() {
    if [[ "$CURRENT" == "active.img" ]]; then
        mv -f ${STATEDIR}/cOS/$CURRENT ${STATEDIR}/cOS/passive.img
        tune2fs -L COS_PASSIVE ${STATEDIR}/cOS/passive.img
    fi

    mv -f ${STATEDIR}/cOS/transition.img ${STATEDIR}/cOS/active.img
    tune2fs -L COS_ACTIVE ${STATEDIR}/cOS/active.img
}

switch_recovery() {
    if is_squashfs; then
        mksquashfs $TARGET ${STATEDIR}/cOS/transition.squashfs -b 1024k -comp xz -Xbcj x86
        mv ${STATEDIR}/cOS/transition.squashfs ${STATEDIR}/cOS/recovery.squashfs
        rm -rf $TARGET
    else
        mv -f ${STATEDIR}/cOS/transition.img ${STATEDIR}/cOS/recovery.img
        tune2fs -L COS_SYSTEM ${STATEDIR}/cOS/recovery.img
    fi
}

ensure_dir_structure() {
    mkdir ${TARGET}/proc || true
    mkdir ${TARGET}/boot || true
    mkdir ${TARGET}/dev || true
    mkdir ${TARGET}/sys || true
    mkdir ${TARGET}/tmp || true
    mkdir ${TARGET}/usr/local || true
    mkdir ${TARGET}/oem || true
}

cleanup2()
{
    rm -rf /usr/local/tmp/upgrade || true
    mount -o remount,ro ${STATE} ${STATEDIR} || true
    if [ -n "${TARGET}" ]; then
        umount ${TARGET}/boot/efi || true
        umount ${TARGET}/ || true
        rm -rf ${TARGET}
    fi
    if [ -n "$UPGRADE_RECOVERY" ] && [ $UPGRADE_RECOVERY == true ]; then
	    umount ${STATEDIR} || true
    fi
    if [ "$STATEDIR" == "/run/initramfs/state" ]; then
        umount ${STATEDIR}
        rm -rf $STATEDIR
    fi
}

cleanup()
{
    EXIT=$?
    cleanup2 2>/dev/null || true
    return $EXIT
}

usage()
{
    echo "Usage: cos-upgrade [--no-verify] [--recovery] [--docker-image] IMAGE"
    echo ""
    echo "Example: cos-upgrade"
    echo ""
    echo "IMAGE is optional, and upgrades the system to the given specified docker image."
    echo ""
    echo ""
    exit 1
}

find_upgrade_channel

while [ "$#" -gt 0 ]; do
    case $1 in
        --docker-image)
            CHANNEL_UPGRADES=false
            ;;
        --recovery)
            UPGRADE_RECOVERY=true
            ;;
        --no-verify)
            VERIFY=false
            ;;
        -h)
            usage
            ;;
        --help)
            usage
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage
            fi
            INTERACTIVE=true
            UPGRADE_IMAGE=$1
            break
            ;;
    esac
    shift 1
done

trap cleanup exit

if [ -n "$UPGRADE_RECOVERY" ] && [ $UPGRADE_RECOVERY == true ]; then
    echo "Upgrading recovery partition.."

    find_partitions

    find_recovery

    mount_recovery

    upgrade

    switch_recovery
else
    echo "Upgrading system.."

    find_partitions

    mount_image

    upgrade

    switch_active
fi

echo "Flush changes to disk"
sync
sync

if [ -n "$INTERACTIVE" ] && [ $INTERACTIVE == false ]; then
    if grep -q 'cos.upgrade.power_off=true' /proc/cmdline; then
        poweroff -f
    else
        echo " * Rebooting system in 5 seconds (CTRL+C to cancel)"
        sleep 5
        reboot -f
    fi
else
    echo "Upgrade done, now you might want to reboot"
fi
