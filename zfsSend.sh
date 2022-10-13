#!/bin/bash

rm -f /var/tmp/zfsbackup.*
while true; do /sbin/zfs snapshot omv1_zfs1/BlueIris@$(date +%Y-%m-%d_%H:%M.%S)_autosnap; sh /root/zfsSnapSend.sh; echo sleeping; sleep 30; rm -f /var/tmp/zfsbackup.lock; done
