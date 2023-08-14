#!/bin/sh
# set -x
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT


FULLBACKUPCYCLE=604800
KEEP=1
BACKDIR=/var/backups/mysql/xtrabackup
BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr
REMOTE="10.0.11.52"


TMPFILE="/tmp/xtrabackup-runner.$$.tmp"
LOGFILE=/var/log/xtrarestorer.log

START=`date +%s`
# LATEST=`find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1` # Find latest backup directory
MINS=$(($FULLBACKUPCYCLE * ($KEEP + 1 ) / 60))
AGE=`stat -c %Y $BASEBACKDIR/latest`

log() {
    echo "[`date '+%Y-%m-%d %H:%M:%S'`]: $@"
}

show_log() {
if [ -z "`tail -1 $TMPFILE | grep 'completed OK!'`" ]
then
  log "RESTORING OF XTRABACKUP FAILED !!!"
  echo "---------- ERROR OUTPUT from xtrabackup ----------"
  cat $TMPFILE
#  rm -f $TMPFILE  
fi
}

cleanup() {
  exit_code=$?
  log "Cleanup..."
  trap - SIGINT SIGTERM ERR EXIT
    if [ $exit_code -ne 0 ]; then
      echo "RESTORE FAILED !!!"
      show_log
    fi
  find $BACKDIR/ -type f ! -name '*.zst' ! -name '*.meta' ! -name 'xtrabackup_checkpoints' -delete
#  rm -f $TMPFILE
  mv -f /tmp/xtrabackup_checkpoints $BASEBACKDIR/latest/xtrabackup_checkpoints
  log "Cleanup Finished"
}

rsync -La --info=progress2 --delete $REMOTE:/$BASEBACKDIR/latest $BASEBACKDIR
rsync -La --info=progress2 --delete $REMOTE:/$INCRBACKDIR/latest $INCRBACKDIR 2> /dev/null|| rm -rf $INCRBACKDIR/latest

# Save xtrabackup_checkpoints
cp $BASEBACKDIR/latest/xtrabackup_checkpoints /tmp/xtrabackup_checkpoints

# Make log
#exec > $LOGFILE 2>&1
echo exe > $LOGFILE
echo "----------------------------"
echo
echo " run-xtrabackup.sh: MySQL backup restorer script"
log "started: `date`"
echo



########################################
#  Check MySQL server and Backup dirs  #
########################################

if [ -z "`zstd --version`" ]
then
  log "ERROR: No zstd package installed"
  log "Please install zstd package:"
  echo
  log "yum install zstd"
  echo
  log "apt install zstd"
fi

if test -d $BASEBACKDIR/latest
then
  log "Backup found"
else
  exit 1
fi

# Check mysqld is running
if [ "`mysqladmin status | grep 'Uptime'`" ]
then
  log "Stop mysql server"; echo
  if ! `systemctl stop mysqld`
  then
    log "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)"; echo
    exit 1
  fi
fi


if pgrep -f "mysqld" > /dev/null
then
    log "Process is running. Attempting to terminate."
    pkill -f "mysqld"
    log "Terminated."
else
    log "Process is not running."
fi


log "Checks completed OK"

### Clean up mysql data
rm -rf /var/lib/mysql/*

#####################
#  Start restoring  #
#####################

log "Decompress backups"
log "Decompressing $BASEBACKDIR/latest"

xtrabackup --decompress --decompress-threads=4 --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1

if [[ -d "$INCRBACKDIR/latest" ]]; then
  subdirs=$(find "$INCRBACKDIR/latest" -mindepth 1 -maxdepth 1 -type d)

  # Loop over all incremental subdirs and decompress them
  for subdir in $subdirs
  do
    log "Decompressing $subdir"
    xtrabackup --decompress --decompress-threads=4 --target-dir=$subdir > $TMPFILE 2>&1
  done
fi

restore_full() {
  log "Prepare Full Backup"
  xtrabackup --prepare --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1
  log "Restore Full Backup"
  xtrabackup --move-back --parallel=4 --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1
  chown -R mysql: /var/lib/mysql/
}

restore_inremental() {
  log "Prepare Incremental Backups"
  xtrabackup --prepare --apply-log-only --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1
  for subdir in $subdirs
  do
    log "Processing $subdir"
    xtrabackup --prepare --apply-log-only --target-dir=$BASEBACKDIR/latest --incremental-dir=$subdir > $TMPFILE 2>&1
    # ls /srv/ps/scripts/xtrabackup/base/2023-07-03_14-15-27/bronix
    # Tut eta hueta dropaet zst faily
  done 
  
  log "Restore Incremental Backup move-back"
  xtrabackup --prepare --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1
  xtrabackup --move-back --parallel=4 --target-dir=$BASEBACKDIR/latest > $TMPFILE 2>&1
  chown -R mysql: /var/lib/mysql/
}

if [[ -d "$INCRBACKDIR/latest" ]]; then
    log "Incremental subdirs is not empty, restore_inremental"
    restore_inremental    
else
    log "Incremental subdirs is empty, restore_full"
    restore_full
fi

log "Restart MySQL Server"
systemctl restart mysqld
echo $?

SPENT=$(((`date +%s` - $START) / 60))
echo
log "took $SPENT minutes"
log "completed: `date`"
./dbs_chk.sh
exit 0
