#!/bin/sh
#set -x
set -Eeuo pipefail

FULLBACKUPCYCLE=604800  # Create a new full backup every X seconds
KEEP=8                  # Number of additional backups cycles a backup should kept for.
ARCHIVES=4              # Number of archives should kept for.
USEROPTIONS=""          # USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST}"
BACKDIR=/var/backups/mysql/xtrabackup


BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr
ARCHBACKDIR=$BACKDIR/arch
TMPFILE="/tmp/xtrabackup-runner.$$.tmp"
LOGFILE=/var/log/xtrabackup.log
START=`date +%s`
LATEST=`find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1` # Find latest backup directory
MINS=$(($FULLBACKUPCYCLE * ($KEEP + 1 ) / 60))
AGE=`stat -c %Y $BASEBACKDIR/$LATEST`

#exec > $LOGFILE 2>&1

# TRAP if something wrong
trap cleanup SIGINT SIGTERM ERR #EXIT

# Function to show log 
show_log() {
if [ -z "`tail -1 $TMPFILE | grep 'completed OK!'`" ]
then
  echo "xtrabackup failed:"; echo
  echo "---------- ERROR OUTPUT from xtrabackup ----------"
  cat $TMPFILE
  rm -f $TMPFILE
  echo
  echo "BACKUP FAILED !!!"
  exit 1
fi
}

# Trap call this function for cleanup
cleanup() {
  trap - SIGINT SIGTERM ERR #EXIT
  rm -rf $TARGETDIR >> /dev/null 2>&1
  show_log
}

### Make Full backup if script started with key -f 
while getopts ":f" opt; do
  case ${opt} in
    f ) 
      # -f was triggered, set FULLBACKUPCYCLE to 1
      FULLBACKUPCYCLE=1
      ;;
    \? ) 
      echo "Invalid option: $OPTARG" 1>&2
      ;;
  esac
done

echo "----------------------------"
echo
echo " run-xtrabackup.sh: MySQL backup script"
echo "started: `date`"
echo



########################################
#  Check MySQL server and Backup dirs  #
########################################

# Test for zstd package installed
if [ -z "`zstd --version`" ]
then
  echo "ERROR: No zstd package installed"
  echo "Please install zstd package:"
  echo
  echo "yum install zstd"
  echo
  echo "apt install zstd"
fi

# Tests for backup dirs exists
if test ! -d $BASEBACKDIR
then
  mkdir -p $BASEBACKDIR
fi

if test ! -d $BASEBACKDIR -o ! -w $BASEBACKDIR
then
  error
  echo $BASEBACKDIR 'does not exist or is not writable'; echo
  exit 1
fi

# check incr dir exists and is writable
if test ! -d $INCRBACKDIR
then
  mkdir -p $INCRBACKDIR
fi

if test ! -d $INCRBACKDIR -o ! -w $INCRBACKDIR
then
  error
  echo $INCRBACKDIR 'does not exist or is not writable'; echo
  exit 1
fi

# check arch dir exists and is writable
if test ! -d $ARCHBACKDIR
then
  mkdir -p $ARCHBACKDIR
fi

if test ! -d $ARCHBACKDIR -o ! -w $ARCHBACKDIR
then
  error
  echo $ARCHBACKDIR 'does not exist or is not writable'; echo
  exit 1
fi

# Check mysqld is running
if [ -z "`mysqladmin $USEROPTIONS status | grep 'Uptime'`" ]
then
  echo "HALTED: MySQL does not appear to be running."; echo
  exit 1
fi

if ! `echo 'exit' | /usr/bin/mysql -s $USEROPTIONS`
then
  echo "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)"; echo
  exit 1
fi

echo "Checks completed OK"

##################
#  Start backup  #
##################


if [ "$LATEST" -a `expr $AGE + $FULLBACKUPCYCLE + 5` -ge $START ]
then
  echo 'New incremental backup'
  # Create an incremental backup

  # Check incr sub dir exists
  # try to create if not
  if test ! -d $INCRBACKDIR/$LATEST
  then
    mkdir -p $INCRBACKDIR/$LATEST
  fi

  # Check incr sub dir exists and is writable
  if test ! -d $INCRBACKDIR/$LATEST -o ! -w $INCRBACKDIR/$LATEST
  then
    echo $INCRBACKDIR/$LATEST 'does not exist or is not writable'
    exit 1
  fi

  LATESTINCR=`find $INCRBACKDIR/$LATEST -mindepth 1  -maxdepth 1 -type d | sort -nr | head -1`
  if [ ! $LATESTINCR ]
  then
    # This is the first incremental backup
    INCRBASEDIR=$BASEBACKDIR/$LATEST
  else
    # This is a 2+ incremental backup
    INCRBASEDIR=$LATESTINCR
  fi

  TARGETDIR=$INCRBACKDIR/$LATEST/`date +%F_%H-%M-%S`

  cleanup() {
    trap - SIGINT SIGTERM ERR #EXIT
    rm -rf $TARGETDIR >> /dev/null 2>&1

    show_log
  }
  # Create incremental Backup
  xtrabackup --backup $USEROPTIONS --target-dir=$TARGETDIR --compress=zstd --compress-threads=4 \
    --incremental-basedir=$INCRBASEDIR > $TMPFILE 2>&1 && ln -sf $INCRBACKDIR/$LATEST $INCRBACKDIR/latest
else
  
  ##############################
  #  Create a new full backup  #
  ##############################


  ##################
  #  Make ARCHIVE  #
  ##################

  # Make archive before full backup  
  # for DEL in `find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -printf "%P\n"`
  # do
  #   # Check full backup exists
  #   if [ ! $DEL ]; then
  #    break
  #   fi
  #   cleanup() {
  #     trap - SIGINT SIGTERM ERR #EXIT
  #     echo "BACKUP FAILED !!!"
  #     rm -rf $ARCHBACKDIR/$DEL.* >> /dev/null 2>&1
  #   }

  #   echo "Archiving $DEL"
  #   tar -cf - -C $BACKDIR base/$DEL incr/ | zstd -T2 > $ARCHBACKDIR/$DEL.tar.zst
  # done
  
  #########################
  #  Delete old archives  #
  #########################

  # ARCHMINS=$(($FULLBACKUPCYCLE * ($ARCHIVES + 1 ) / 60))
  
  # for DEL in `find $ARCHBACKDIR -mindepth 1 -maxdepth 1 -type f  -mmin +$ARCHMINS -printf "%P\n"`
  # do
  #   if [ ! $DEL ]; then
  #    break
  #   fi
  #   echo "Cleaning up old archives"
  #   echo "Deleting Archive $DEL"
  #   echo
  #   rm -rf $ARCHBACKDIR/$DEL
  # done
  
  ########################
  #  Delete old bakcups  #
  ########################
  
  echo "Cleaning up old backups (older than $MINS minutes) and temporary files"
  for DEL in `find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -printf "%P\n"`
  do
    if [ ! $DEL ]; then
     echo "Old backups (older than $MINS minutes) does not exists"
     break
    fi
    echo
    echo "Deleting Backup $DEL"
    rm -rf $BASEBACKDIR/$DEL
    rm -rf $INCRBACKDIR/$DEL
  done
  
  ##############################
  #  Create a new full backup  #
  ##############################

  echo 'New full backup'
  TARGETDIR=$BASEBACKDIR/`date +%F_%H-%M-%S`

  cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    rm -rf $TARGETDIR >> /dev/null 2>&1
    
    show_log
  }

  xtrabackup --backup $USEROPTIONS --compress=zstd --compress-threads=4 \
    --target-dir=$TARGETDIR > $TMPFILE 2>&1 && ln -sf $TARGETDIR $BASEBACKDIR/latest && rm $INCRBACKDIR/latest

fi


show_log

THISBACKUP=`awk -- "/Backup created in directory/ { split( \\\$0, p, \"'\" ) ; print p[2] }" $TMPFILE`

echo "Databases backed up successfully to: $THISBACKUP"
echo


# Delete tmp file
rm -f $TMPFILE

SPENT=$(((`date +%s` - $START) / 60))
echo
echo "took $SPENT minutes"
echo "completed: `date`"
exit 0
