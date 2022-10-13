#!/bin/bash
# Needs a POSIX-compatible sh, like ash (Debian & FreeBSD /bin/sh), ksh, or
# bash.  On Solaris 10 you need to use /usr/xpg4/bin/sh (the POSIX shell) or
# /bin/ksh -- its /bin/sh is an ancient Bourne shell, which does not work.

# backup script to replicate a ZFS filesystem and its children to another
# server via zfs snapshots and zfs send/receive
#
# SMF manifests welcome!

# v0.7 per zfs local and remote retention by Colt Boyd <coltboyd@gmail.com>
# v0.6 various changes around snapshot retention and removal by Colt Boyd <coltboyd@gmail.com>
# v0.5 changed to discover and use the newest common snapshot by Erik.
# v0.4 (unreleased) - misc. fixes; portability & doc improvements
# v0.3 - cmdline options and cfg file support
# v0.2 - multiple datasets
# v0.1 - initial working version

# Copyright (c) 2009-15 Andrew Daugherity <adaugherity@tamu.edu>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.


# Basic installation: After following the prerequisites, run manually to verify
# operation, and then add a line like the following to zfssnap's crontab: (or run it once per day)
# 30 * * * * /path/to/zfs-backup.sh
#
# Consult the README file for details.

# It's probably best to do a dry-run first (zfs-backup.sh -nv).


# PROCEDURE:
#   * find newest local snapshot
#   * find newest common snapshot
#   * check that both $newest_local and $latest_remote snaps exist locally
#   * zfs send incremental (-I) from $newest_common to $latest_local to dsthost
#   * if anything fails, set svc to maint. and exit

# all of the following variables (except CFG) may be set in the config file
DEBUG=""                # set to non-null to enable debug (dry-run)
VERBOSE=""              # "-v" for verbose, null string for quiet
LOCK="/var/tmp/zfsbackup.lock"
PID="/var/tmp/zfsbackup.pid"
CFG="/etc/zfs-backup/zfs-backup.cfg"
# local snap list temp save file
LOCSNAPFILE="/var/tmp/snap.local"
# remote snap list temp save file
REMSNAPFILE="/var/tmp/snap.remote"
ZFS="/sbin/zfs"

#the snapshots to use should contain this string as part of their name. It is assumed these can be sorted to make a timeline
TAG="_autosnap"
# Default Keep n most recent snapshots on local side
DEFLOCRETNUM=6
# Default Keep n most recent snapshots on remote side
DEFREMRETNUM=13
# local settings -- datasets to back up are now found by property
PROPTARGET="zfs.send:backuptarget"
PROPLOCALRETENTION="zfs.send:localretention"
PROPREMOTERETENTION="zfs.send:remoteretention"
# set with command:
# zfs set edu.tamu:backuptarget=tank/syncthing pool/syncthing
# remote settings (on destination host)
REMUSER="root"
# special case: when $REMHOST=localhost, ssh is bypassed
REMHOST="10.99.97.1"
REMPOOL="omv2_zfs1"
REMZFS="$ZFS"


usage() {
    echo "Usage: $(basename $0) [ -nv ] [-r N ] [ [-f] cfg_file ]"
    echo "  -n\t\tdebug (dry-run) mode"
    echo "  -v\t\tverbose mode"
    echo "  -f\t\tspecify a configuration file"
    echo "If the configuration file is last option specified, the -f flag is optional."
    exit 1
}

# Option parsing
set -- $(getopt h?nvf:r: $*)
if [ $? -ne 0 ]; then
    usage
fi
for opt; do
    case $opt in
        -h|-\?) usage;;
        -n) dbg_flag=Y; shift;;
        -v) verb_flag=Y; shift;;
        -f) CFG=$2; shift 2;;
        --) shift; break;;
    esac
done
if [ $# -gt 1 ]; then
    usage
elif [ $# -eq 1 ]; then
    CFG=$1
fi
# If file is in current directory, add ./ to make sure the correct file is sourced
if [ $(basename $CFG) = "$CFG" ]; then
    CFG="./$CFG"
fi
# Read any settings from a config file, if present
if [ -r $CFG ]; then
    # Pass its name as a parameter so it can use $(dirname $1) to source other
    # config files in the same directory.
    . $CFG $CFG
fi
# Set options now, so cmdline opts override the cfg file
[ "$dbg_flag" ] && DEBUG=1
[ "$verb_flag" ] && VERBOSE="-v"
# local (non-ssh) backup handling: REMHOST=localhost
if [ "$REMHOST" = "localhost" ]; then
    REMZFS_CMD="$ZFS"
else
    REMZFS_CMD="ssh $REMUSER@$REMHOST $REMZFS"
fi

# Usage: do_backup pool/fs/to/backup receive_option
#   receive_option should be -d for full path and -e for base name
#   See the descriptions in the 'zfs receive' section of zfs(1M) for more details.
do_backup() {
echo " $*"
    DATASET=$1
    TARGET=$2
    REMPOOL="$(dirname $TARGET)"
    REMPOOL=$2

    newest_local="$($ZFS list -t snapshot -H -S creation -o name -d 1 $DATASET | grep $TAG | head -1)"
    if [ -z "$newest_local" ]; then
        echo "Error: no snapshots matching tag '$TAG' for ${DATASET}!" >&2
        return 1
    fi
    msg="newest local snapshot:"
    snap2=${newest_local#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "$msg $snap2"


# get both snapshot lists
#       zfs list -t snapshot -H -S creation -o name -d 1 pool/syncthing | grep auto | sort | sed 's/.*@//' > $LOCSNAPFILE
#       ssh -n root@192.168.0.67 zfs list -t snapshot -H -S creation -o name -d 1 tank/syncthing | grep auto | sort | sed 's/.*@//' > $REMSNAPFILE
#find newest common
#        comm -12 $LOCSNAPFILE $REMSNAPFILE | tail -1



    # get complete list of local snapshots containing TAG
    $ZFS list -t snapshot -H -S creation -o name -d 1 $DATASET | grep $TAG | sort | sed 's/.*@//' > $LOCSNAPFILE

    if [ "$REMHOST" = "localhost" ]; then
        newest_remote="$($ZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | head -1)"
        list_remote="$($ZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | sort -r)"
        $ZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | sort | sed 's/.*@//' > $REMSNAPFILE
        err_msg="Error fetching snapshot listing for local target pool $REMPOOL."
    else
        # ssh needs public key auth configured beforehand
        # Not using $REMZFS_CMD because we need 'ssh -n' here, but must not use
        # 'ssh -n' for the actual zfs recv.
        newest_remote="$(ssh -n $REMUSER@$REMHOST $REMZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | head -1)"
        list_remote="$(ssh -n $REMUSER@$REMHOST $REMZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | sort -r)"
        ssh -n $REMUSER@$REMHOST $REMZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | sort | sed 's/.*@//' > $REMSNAPFILE
        err_msg="Error fetching remote snapshot listing via ssh to $REMUSER@$REMHOST."
    fi

    newest_common="$(comm -12 $LOCSNAPFILE $REMSNAPFILE | tail -1)"
        echo "$newest_common"

    if [ -z $newest_common ]; then
        echo "$err_msg" >&2
        [ $DEBUG ] || touch $LOCK
        return 1
    fi

    snap1=${newest_common#*@}
    [ "$DEBUG" -o "$VERBOSE" ] && echo "newest common snapshot: $snap1"

    if ! $ZFS list -t snapshot -H $DATASET@$snap1 > /dev/null 2>&1; then
        exec 1>&2
        echo "Newest common snapshot '$snap1' does not exist locally!"
        echo "Perhaps it has been already rotated out."
        echo ""
        echo "Manually run zfs send/recv to bring $TARGET on $REMHOST"
        echo "to a snapshot that exists on this host (newest local snapshot with the"
        echo "tag $TAG is $snap2)."
        [ $DEBUG ] || touch $LOCK
        return 1
    fi

    if ! $ZFS list -t snapshot -H $DATASET@$snap2 > /dev/null 2>&1; then
        exec 1>&2
        echo "Something has gone horribly wrong -- local snapshot $snap2"
        echo "has suddenly disappeared!"
        [ $DEBUG ] || touch $LOCK
        return 1
    fi

    if [ "$snap1" = "$snap2" ]; then
        [ $VERBOSE ] && echo "Common snapshot is the same as newest local; not running."
        return 0
    fi

    if [ $DEBUG ]; then
        echo "would run: $ZFS send --compressed -I $snap1 $DATASET@$snap2 |"
#        echo "would run: $ZFS send --compressed -R -I $snap1 $DATASET@$snap2 |"
        echo "  $REMZFS_CMD recv $VERBOSE -F $REMPOOL"
    else

        if ! $ZFS send --compressed -I $snap1 $DATASET@$snap2 | \
#        if ! $ZFS send --compressed -R -I $snap1 $DATASET@$snap2 | \
          $REMZFS_CMD recv $VERBOSE -F $REMPOOL; then
            echo 1>&2 "Error sending snapshot."
            touch $LOCK
            return 1
        else
                        REMRETNUM=$($ZFS get -s local -H -o value $PROPREMOTERETENTION $DATASET)
                        if [ $REMRETNUM -lt 1 ]; then
                                REMRETNUM=$DEFREMRETNUM
                        fi
                        LOCRETNUM=$($ZFS get -s local -H -o value $PROPLOCALRETENTION $DATASET)
                        if [ $LOCRETNUM -lt 1 ]; then
                                LOCRETNUM=$DEFLOCRETNUM
                        fi
            ssh -n $REMUSER@$REMHOST $REMZFS list -t snapshot -H -S creation -o name -d 1 $TARGET | grep $TAG | sort | sed 's/.*@//' > $REMSNAPFILE
            cat $LOCSNAPFILE | grep -v "$(comm -12 $LOCSNAPFILE $REMSNAPFILE | tail -1)" | head -n -$LOCRETNUM | xargs -I {} -n 1 $ZFS destroy -r $DATASET@{}
            cat $REMSNAPFILE | grep -v "$(comm -12 $REMSNAPFILE $LOCSNAPFILE | tail -1)" | head -n -$REMRETNUM | xargs -I {} -n 1 ssh -n $REMUSER@$REMHOST $REMZFS destroy -r $TARGET@{}
        fi
    fi
}

# begin main script
if [ -e $LOCK ]; then
    # this would be nicer as SMF maintenance state
    if [ -s $LOCK  ]; then
        # in normal mode, only send one email about the failure, not every run
        if [ "$VERBOSE" ]; then
            echo "Service is in maintenance state; please correct and then"
            echo "rm $LOCK before running again."
        fi
    else
        # write something to the file so it will be caught by the above
        # test and cron output (and thus, emails sent) won't happen again
        echo "Maintenance mode, email has been sent once." > $LOCK
        echo "Service is in maintenance state; please correct and then"
        echo "rm $LOCK before running again."
    fi
    exit 2
fi

if [ -e "$PID" ]; then
    [ "$VERBOSE" ] && echo "Backup job already running!"
    exit 0
fi
echo $$ > $PID

FAIL=0
# get the datasets that have our backup property set
COUNT=$($ZFS get -s local -H -o name,value $PROPTARGET | wc -l)
if [ $COUNT -lt 1 ]; then
    echo "No datasets configured for backup!  Please set the '$PROPTARGET' property"
    echo "appropriately on the datasets you wish to back up."
    rm $PID
    exit 2
fi

$ZFS get -s local -H -o name,value $PROPTARGET |
while read dataset value
do
    do_backup $dataset $value
    STATUS=$?
    if [ $STATUS -gt 0 ]; then
        FAIL=$((FAIL | STATUS))
    fi
done

if [ $FAIL -gt 0 ]; then
    if [ $((FAIL & 1)) -gt 0 ]; then
        echo "There were errors backing up some datasets." >&2
    fi
    if [ $((FAIL & 2)) -gt 0 ]; then
        echo "Some datasets had misconfigured $PROPTARGET properties." >&2
    fi
fi

rm $PID
exit $FAIL
