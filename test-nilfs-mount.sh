#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+

cmd=`basename $0`
cdir=`dirname $0`

function die() { echo -e "\e[31m${1}\e[m" 1>&2; exit 1; }

function print_usage() {
    echo "Usage: $cmd [-v] [-d device] <mount-point> <snapshot-mount-point>"
    echo "       $cmd [-h]"
    echo "Description:"
    echo "  Test the operation and status of various nilfs2 mount patterns."
    echo "Required tools:"
    echo "  - nilfs-utils (available from https://github.com/nilfs-dev/nilfs-utils.git)"
    echo "  - core-utils, util-linux, procps-ng (pgrep), gawk"
    echo "Example of use:"
    echo "  $ sudo mkfs -t nilfs2 /dev/vdb1"
    echo "  $ sudo ./test-nilfs-mount.sh -d /dev/vdb1 /mnt/test /mnt/snapshot"
}

function is_nilfs_mountpoint() {
    test $(stat -fc "%t" "$1") = 3434 -a $(stat -c "%i" "$1") -eq 2
}

function get_device() {
    # $1: mount point
    df "$1" | awk 'NR>1{print $1; quit;}'
}

function get_snapshot_cno() {
    # $1: device
    lscp -sr $1 | awk 'NR>1{print $1; quit;}'
}

# Escape pathname string (only spaces are supported)
function pathname_escape() {
    # $1: path
    echo "${1/ /\\ }"
}

# Regular expression for path name in mount table (escaping only spaces)
function mtab_escape_re() {
    # $1: path
    echo "${1/ /\\\\040}"
}

randfile=/tmp/100K.dat

opwait=1  # Operation interval (one second)
verbose=0
device=""

while getopts d:hv OPT
do
    case $OPT in
	d)
	    device="$OPTARG" ;;
	h)
	    print_usage
	    exit 0
	    ;;
	v)
	    verbose=1 ;;
	*)
	    print_usage
	    exit 1
	    ;;
    esac
done
shift `expr $OPTIND - 1`

#
test -n "$1" || { print_usage; exit 0; }
mntdir="$1"
_mntdir="$(pathname_escape "$mntdir")"

shift 1
test -n "$1" || { print_usage; exit 0; }
ssdir="$1"
_ssdir="$(pathname_escape "$ssdir")"

if [ -n "$device" ]; then
    test -b "$device" || die "$device is not a block device"
    test -n "$(blkid -t TYPE=nilfs2 $device)" ||
	die "$device is not a nilfs device"
fi

# Intermediate variables
testfile="$mntdir/test-mount.dat"
utab="/var/run/mount/utab"

# Sundries
function gc_pid() {
    pgrep -f "nilfs_cleanerd $device $mntdir"
}

function gc_kill() {
    local gcpid="$(gc_pid)"
    test -z "$gcpid" || kill "$gcpid"
}

# Create mount directory
for md in "$mntdir" "$ssdir"; do
    if [ ! -d "$md" ]; then
	echo "mount directory '$md' does not exist - create it."
	mkdir -p "$md"
    fi
done

# Make the test mount point mounted
if is_nilfs_mountpoint "$mntdir"; then
    if [ -z "$device" ]; then
	device=$(get_device "$mntdir")
    else
	test $(get_device "$mntdir") = "$device" ||
	    die "$device differs from the device mounted on $_mntdir."
    fi
elif [ -z "$device" ]; then
    die "$_mntdir is not a NILFS mount-point and no nilfs device given."
else
    mount -t nilfs2 "$device" "$mntdir"
fi

# Create a test data file
if [ ! -e "$randfile" ]; then
    echo "create random file '${randfile}'"
    dd if=/dev/urandom "of=${randfile}" bs=1K count=100
fi

scno="$(get_snapshot_cno $device)"
if [ -z "$scno" ]; then
    echo "NILFS on $_mntdir has no snapshots - create it."


    cp "${randfile}" "${testfile}"
    mkcp -s

    scno=$(get_snapshot_cno "$device")
fi

echo "Preparation complete - once unmount $_mntdir"
umount "$mntdir" || {
    gc_kill && umount "${mntdir}" || die "failed to unmount $_mntdir"
}
sleep 1


# utab pattern checkers
check_utab() {
    # $1: expected utab attribute pattern (grep regular expression)
    local re='^\(ID=[0-9]\+ \)\?SRC='${device}' TARGET='$(mtab_escape_re "$mntdir")' ROOT=[^ ]\+'"${1:+ ATTRS=$1}"
    test -f "$utab" || die "utab doesn't exists as expected"
    grep -e "$re" ${utab} > /dev/null ||
	die "utab didn't match with the expected pattern '$re'"
}

check_noutab() {
    # $1: mount point (optional)
    local mp="${1:-"$mntdir"}"
    local re='^\(ID=[0-9]\+ \)\?SRC='${device}' TARGET='$(mtab_escape_re "$mp")
    test -f "$utab" || return 0
    grep -e "$re" ${utab} > /dev/null &&
	die "utab unexpectedly exists for '$device' on '$mp'"
    return 0
}

check_utab_with_gc() {
    check_utab "gcpid=$(gc_pid)"
}

check_utab_with_nogc() {
    check_utab "nogc"
}

check_utab_with_none() {
    check_utab "none"
}

# cleanerd checkers
check_cleanerd() {
    pgrep -f "nilfs_cleanerd $device $mntdir" > /dev/null ||
	die "No cleanerd found as expected for $device on '$mntdir'"
}

check_no_cleanerd() {
    local mp="${1:-"$mntdir"}"
    ! pgrep -f "nilfs_cleanerd $device $mp" > /dev/null ||
	die "cleanerd unexpectedly found for $device on '$mp'"
}

# mount checkers
is_mounted() {
    # $1: mount point
    local script='NR>1 && $1 == "'$device'" {found=1;quit;}END{exit !found;}'
    df -at nilfs2 "$1" 2>/dev/null | awk "$script"
}

check_mount() {
    # $1: mount point (optional)
    local mp="${1:-"$mntdir"}"
    is_mounted "$mp" || die "No nilfs2 mount found for $device on '$mp'"
}

check_no_mount() {
    # $1: mount point (optional)
    local mp="${1:-"$mntdir"}"
    ! is_mounted "$mp" ||
	die "nilfs2 mount unexpectedly found for $device on '$mp'"
}

# mount command exec function
step_debug() {
    test $verbose -ne 0 || return 0

    if [ -f "$utab" ]; then
	echo "utab file:"
	cat $utab
    else
	echo "no utab file"
    fi
    return 0
}

exec_mount_cmd() {
    # $*: command line
    echo "- $*" && eval "$*" && step_debug
}


# Other helpers for testing
use_rw() {
    cp "${randfile}" "$mntdir/${FUNCNAME[1]}.dat"
    mkcp $device
    sleep $opwait
}

use_ro() {
    cat "$(find "$mntdir" -type f -print -quit)" > /dev/null
    sleep $opwait
}

use_ss() {
    cat "$(find "$ssdir" -type f -print -quit)" > /dev/null
    sleep $opwait
}


# Test cases
test_1() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_2() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_3() {
    if [ "$1" = "-h" ]; then
	echo "mount (nogc) & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -o nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_4() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & ro remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_5() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & ro remount & rw remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_6() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & nogc remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_7() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & nogc remount & rw remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_8() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & nogc remount & ro remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_9() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & rw remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_10() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & rw remount & ro remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_11() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & nogc remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_12() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & nogc remount & rw remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_13() {
    if [ "$1" = "-h" ]; then
	echo "mount (ro) & nogc remount & ro remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -r $device $_mntdir" &&
	check_mount && check_noutab && check_no_cleanerd && use_ro &&
	exec_mount_cmd "mount -t nilfs2 -o remount,nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_14() {
    if [ "$1" = "-h" ]; then
	echo "mount (nogc) & rw remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -o nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,rw $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_15() {
    if [ "$1" = "-h" ]; then
	echo "mount (nogc) & ro remount & umount"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -o nogc $device $_mntdir" &&
	check_mount && check_utab_with_nogc && check_no_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd && use_ro &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}

test_16() {
    if [ "$1" = "-h" ]; then
	echo "mount (rw) & snapshot mount & umount (rw) & umount (snapshot)"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o ro,cp=${scno} $device $_ssdir" &&
	check_mount "$ssdir" && check_utab_with_gc && check_cleanerd && check_no_cleanerd "$ssdir" && use_ss &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd &&
	check_no_cleanerd "$ssdir" && use_ss &&
	exec_mount_cmd "umount $_ssdir" &&
	check_no_mount "$ssdir" && check_noutab && check_no_cleanerd
}

test_17() {
    if [ "$1" = "-h" ]; then
	echo "mount (snapshot) & mount (rw) && mount (remount, ro) & umount (snapshot) & umount (ro)"
	return
    fi
    exec_mount_cmd "mount -t nilfs2 -o ro,cp=${scno} $device $_ssdir" &&
	check_mount "$ssdir" && check_noutab &&
	check_no_cleanerd "$ssdir" && use_ss &&
	exec_mount_cmd "mount -t nilfs2 $device $_mntdir" &&
	check_mount && check_utab_with_gc && check_cleanerd &&
	check_no_cleanerd "$ssdir" && use_rw &&
	exec_mount_cmd "mount -t nilfs2 -o remount,ro $device $_mntdir" &&
	check_mount && check_utab_with_none && check_no_cleanerd &&
	check_no_cleanerd "$ssdir" && use_ro &&
	exec_mount_cmd "umount $_ssdir" &&
	check_no_mount "$ssdir" && check_utab_with_none &&
	check_no_cleanerd &&
	exec_mount_cmd "umount $_mntdir" &&
	check_no_mount && check_noutab && check_no_cleanerd
}
NTESTS=17

# Run tests
let i=1
while (($i <= $NTESTS)); do
    testname="test_${i}"

    echo "=== Start $testname: $(eval $testname -h)"
    $testname || die "$testname failed."
    echo "$testname succeeded."

    let i++
done

echo "Done all tests."
exit 0
