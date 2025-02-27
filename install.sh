#!/bin/sh
#
# Copyright (c) 2010 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This attempts to guide linux users through the process of putting a recovery
# image onto a removeable USB drive.
#
# We may not need root privileges if we have the right permissions.
#
set -eu

##############################################################################
# Configuration goes here

# Where should we do our work? Use 'WORKDIR=' to make a temporary directory,
# but using a persistent location may let us resume interrupted downloads or
# run again without needing to download a second time.
WORKDIR=${WORKDIR:-/home/chronos/user/tmp.crosrec}

# Where do we look for the config file? We can override this for debugging by
# specifying "--config URL" on the command line, but curl and wget may handle
# file URLs differently.
CONFIGURL="${2:-https://raw.githubusercontent.com/craigbeat/BringChromeHome/master/recovery.conf}"

# Device to put this stuff on, perhaps the user knows best?
DEVICE="${DEVICE:-}"

# Chrome OS Model. This lets us run:
# MODEL=`hardware_class` sh linux_recovery.sh
# and automatically grab the right image.
MODEL="${MODEL:-}"

# What version is this script? It must match the 'recovery_tool_version=' value
# in the config file that we'll download.
MYVERSION='0.9.2'


##############################################################################
# Some temporary filenames
debug='debug.log'
tmpfile='tmp.txt'
config='config.txt'
version='version.txt'

##############################################################################
# Various warning messages

DEBUG() {
  echo "DEBUG: $@" >>"$debug"
}

prompt() {
  # builtin echo may not grok '-n'. We should always have /bin/echo, right?
  /bin/echo -n "$@"
}

warn() {
  echo "$@" 1>&2
}

quit() {
  warn "quitting..."
  exit 1
}

fatal() {
  warn "ERROR: $@"
  exit 1
}

ufatal() {
  warn "
ERROR: $@

You may need to run this program as a different user. If that doesn't help, try
using a different computer, or ask a knowledgeable friend for help.

"
  exit 1
}

gfatal() {
  warn "
ERROR: $@

You may need to run this program as a different user. If that doesn't help, it
may be a networking problem or a problem with the images provided by Google.
You might want to check to see if there is a newer version of this tool
available, or if someone else has already reported a problem.

If all else fails, you could try using a different computer, or ask a
knowledgeable friend for help.

"
  exit 1
}

##############################################################################
# Identify the external utilities that we MUST have available.
#
# I'd like to keep the set of external *NIX commands to an absolute minimum,
# but I have to balance that against producing mysterious errors because the
# shell can't always do everything. Let's make sure that these utilities are
# all in our $PATH, or die with an error.
#
# This also sets the following global variables to select alternative utilities
# when there is more than one equivalent tool available:
#
#   FETCH          = name of utility used to download files from the web
#   CHECK          = command to invoke to generate checksums on a file
#   CHECKTYPE      = type of checksum generated
#   DISKUTIL       = set if we have 'diskutil' (for Macs)
#
require_utils() {
  local extern
  local errors
  local tool
  local tmp

  extern='awk cat cut dd grep ls mkdir mount readlink sed sync umount wc'
  if [ -z "$WORKDIR" ]; then
    extern="$extern mktemp"
  fi
  errors=

  for tool in $extern ; do
    if ! type "$tool" >/dev/null 2>&1 ; then
      warn "ERROR: need \"$tool\""
      errors=yes
    fi
  done

  # We need a tool to decompress the .zip file. unzip is available on most platforms
  # but not CrOS so we can use zcat there.
  DECOMPRESS=
  if [ -z "$DECOMPRESS" ] && tmp=$(type unzip 2>/dev/null) ; then
    DECOMPRESS=unzip
  fi
  if [ -z "$DECOMPRESS" ] && tmp=$(type zcat 2>/dev/null) ; then
    DECOMPRESS=zcat
  fi
  if [ -z "$DECOMPRESS" ]; then
    warn "ERROR: need \"unzip\" or \"zcat\""
	errors=yes
  fi

  # We also need to a way to fetch files from teh internets. Note that the args
  # are different depending on which utility we find. We'll use two variants,
  # one to fetch fresh every time and one to try again from where we left off.
  FETCH=
  if [ -z "$FETCH" ] && tmp=$(type curl 2>/dev/null) ; then
    FETCH=curl
  fi
  if [ -z "$FETCH" ] && tmp=$(type wget 2>/dev/null) ; then
    FETCH=wget
  fi
  if [ -z "$FETCH" ]; then
    warn "ERROR: need \"curl\" or \"wget\""
    errors=yes
  fi

  # Once we've fetched a file we need to compute its checksum. There are
  # multiple possiblities here too.
  CHECK=
  if [ -z "$CHECK" ] && tmp=$(type md5sum 2>/dev/null) ; then
    CHECK="md5sum"
    CHECKTYPE="md5"
  fi
  if [ -z "$CHECK" ] && tmp=$(type sha1sum 2>/dev/null) ; then
    CHECK="sha1sum"
    CHECKTYPE="sha1"
  fi
  if [ -z "$CHECK" ] && tmp=$(type openssl 2>/dev/null) ; then
    CHECK="openssl"
    CHECKTYPE="md5"
  fi
  if [ -z "$CHECK" ]; then
    warn "ERROR: need \"md5sum\" or \"sha1sum\" or \"openssl\""
    errors=yes
  fi

  # This utility is on Macs, so use it if we find it.
  DISKUTIL=
  if type diskutil >/dev/null 2>&1; then
    DISKUTIL=diskutil
  fi

  if [ -n "$errors" ]; then
    ufatal "Some required utilities are missing."
  fi
}

# This retrieves a URL and stores it locally. It uses the global variable
# 'FETCH' to determine the utility (and args) to invoke.
# Args:  URL FILENAME [RESUME]
fetch_url() {
  local url
  local filename
  local resume
  local err

  url="$1"
  filename="$2"
  resume="${3:-}"

  DEBUG "FETCH=($FETCH) url=($url) filename=($filename) resume=($resume)"
  if [ "$FETCH" = "curl" ]; then
    if [ -z "$resume" ]; then
      # quietly fetch a new copy each time
      rm -f "$filename"
      curl -L -f -s -S -o "$filename" "$url"
    else
      # continue where we left off, if possible
      curl -L -f -C - -o "$filename" "$url"
      # If you give curl the '-C -' option but the file you want is already
      # complete and the server doesn't report the total size correctly, it
      # will report an error instead of just doing nothing. We'll try to work
      # around that.
      err=$?
      if [ "$err" = "18" ]; then
        warn "Ignoring spurious complaint"
        true
      fi
    fi
  elif [ "$FETCH" = "wget" ]; then
    if [ -z "$resume" ]; then
      # quietly fetch a new copy each time
      rm -f "$filename"
      wget -nv -q -O "$filename" "$url"
    else
      # continue where we left off, if possible
      wget -c -O "$filename" "$url"
    fi
  fi
}

# This returns a checksum on a file. It uses the global variable 'CHECK' to
# determine the utility (and args) to invoke.
# Args:  FILENAME
compute_checksum() {
  local filename

  filename="$1"

  DEBUG "CHECK=($CHECK) CHECKTYPE=($CHECKTYPE)"

  if [ "$CHECK" = "openssl" ]; then
    openssl md5 < "$filename"
  else
    $CHECK "$zipfile" | cut -d' ' -f1
  fi
}


##############################################################################
# Helper functions to handle the config file and image zipfile.

# Convert bytes to MB, rounding up to determine storage needed to hold bytes.
roundup() {
  local num=$1
  local div=$(( 1024 * 1024 ))
  local rem=$(( $num % $div ))

  if [ $rem -ne 0 ]; then
    num=$(($num + $div - $rem))
  fi
  echo $(( $num / $div ))
}


# Die unless the filesystem containing the current directory has enough free
# space. The argument is the number of MB required.
verify_tmp_space() {
  local need
  local got
  need="$1"

  # The output of "df -m ." could take two forms:
  #
  # Filesystem           1M-blocks      Used Available Use% Mounted on
  # /some/really/long/path/to/some/where
  #                          37546     11118     24521  32% /
  #
  # Filesystem         1048576-blocks      Used Available Capacity Mounted on
  # /some/short/path         37546     11118     24521      32% /
  #
  got=$(df -m . | awk '/^\/[^ ]+ +[0-9]/ {print $4} /^ +[0-9]/ {print $3}')

  if [ "$need" -gt "$got" ]; then
    fatal " There is not enough free space in ${WORKDIR}" \
"(it has ${got}MB, we need ${need}MB).

Please free up some space on that filesystem, or specify a temporary directory
on the commandline like so:

  WORKDIR=/path/to/some/dir  $0
"
  fi
}


# Each paragraph in the config file should describe a new image. Let's make
# sure it follows all the rules. This scans the config file and returns success
# if it looks valid. As a side-effect, it lists the line numbers of the start
# and end of each stanza in the global variables 'start_lines' and 'end_lines'
# and saves the total number of images in the global variable 'num_images'.
good_config() {
  local line
  local key
  local val
  local name
  local file
  local zipfilesize
  local filesize
  local url
  local md5
  local sha1
  local skipping
  local errors
  local count
  local line_num

  name=
  file=
  zipfilesize=
  filesize=
  url=
  md5=
  sha1=
  skipping=yes
  errors=
  count=0
  line_num=0

  # global
  start_lines=
  end_lines=

  while read line; do
    line_num=$(( line_num + 1 ))

    # We might have some empty lines before the first stanza. Skip them.
    if [ -n "$skipping" ] && [ -z "$line" ]; then
      continue
    fi

    # Got something...
    if [ -n "$line" ]; then
      key=${line%=*}
      val=${line#*=}
      if [ -z "$key" ] || [ -z "$val" ] || [ "$key=$val" != "$line" ]; then
        DEBUG "ignoring $line"
        continue
      fi

      # right, looks good
      if [ -n "$skipping" ]; then
        skipping=
        start_lines="$start_lines $line_num"
      fi

      case $key in
        name)
          if [ -n "$name" ]; then
            DEBUG "duplicate $key"
            errors=yes
          fi
          name="$val"
          ;;
        file)
          if [ -n "$file" ]; then
            DEBUG "duplicate $key"
            errors=yes
          fi
          file="$val"
          ;;
        zipfilesize)
          if [ -n "$zipfilesize" ]; then
            DEBUG "duplicate $key"
            errors=yes
          fi
          zipfilesize="$val"
          ;;
        filesize)
          if [ -n "$filesize" ]; then
            DEBUG "duplicate $key"
            errors=yes
          fi
          filesize="$val"
          ;;
        url)
          url="$val"
          ;;
        md5)
          md5="$val"
          ;;
        sha1)
          sha1="$val"
          ;;
      esac
    else
      # Between paragraphs. Time to check what we've found so far.
      end_lines="$end_lines $line_num"
      count=$(( count + 1))

      if [ -z "$name" ]; then
        DEBUG "image $count is missing name"
        errors=yes
      fi
      if [ -z "$file" ]; then
        DEBUG "image $count is missing file"
        errors=yes
      fi
      if [ -z "$zipfilesize" ]; then
        DEBUG "image $count is missing zipfilesize"
        errors=yes
      fi
      if [ -z "$filesize" ]; then
        DEBUG "image $count is missing filesize"
        errors=yes
      fi
      if [ -z "$url" ]; then
        DEBUG "image $count is missing url"
        errors=yes
      fi
      if [ "$CHECKTYPE" = "md5" ] && [ -z "$md5" ]; then
        DEBUG "image $count is missing required md5"
        errors=yes
      fi
      if [ "$CHECKTYPE" = "sha1" ] && [ -z "$sha1" ]; then
        DEBUG "image $count is missing required sha1"
        errors=yes
      fi

      # Prepare for next stanza
      name=
      file=
      zipfilesize=
      filesize=
      url=
      md5=
      sha1=
      skipping=yes
    fi
  done < "$config"

  DEBUG "$count images found"
  num_images="$count"

  DEBUG "start_lines=($start_lines)"
  DEBUG "end_lines=($end_lines)"

  # return error status
  [ "$count" != "0" ] && [ -z "$errors" ]
}


# Make the user pick an image to download. On success, it sets the global
# variable 'user_choice' to the selected image number.
display_images(){
   local count
   local line
   #Declaring variables
   count=0
   #Starting from 0
   while read line; do
      #Reading lines
          # Got something...
          if [ -n "$line" ]; then
          #If there's a line
              key=${line%=*}
              val=${line#*=}
              if [ -z "$key" ] || [ -z "$val" ] || [ "$key=$val" != "$line" ]; then
                  #If line should be ignored
                  DEBUG "ignoring $line"
                  #Debug message
                  continue
                  #Back to start of loop
               elif [ "$count" -ge $2 ] || [ "$count" -lt $1 ]; then
                  #If we don't want to display this option
                  case $key in
                  name)
                      count=$(( count + 1 ))
                      #Incrementing count anyway, to make sure then user number selection works later
                  esac
                  continue
                  #Back to start of loop
              fi
              case $key in
                  name)
                      count=$(( count + 1 ))
                      #Incrementing number found
                      echo "$count - $val"
                      #Outputting option
                      ;;
              esac
          fi
      done < "$config"
}
choose_image() {
   local count
  local show
  local num
  local min
  local max
  #Declaring variables
  min=0
  max=40
  #By default, we should start by showing options 1 - 40
   num=""
   #Setting default value
  show=yes
  #Show by default
  while [ "$num" == "m" ] || [[ -z "$num" ]]; do
  #Until the user has made a choice
    if [ -n "$show" ]; then
      #echo "If you know the Model string displayed at the recovery screen,"
      #prompt "type some or all of it; otherwise just press Enter: "
      #read hwidprefix

      if [ "$num_images" -gt 1 ]; then
        echo "There are $num_images recovery images to choose from:"
      else
        echo "There is $num_images recovery image to choose from:"
      fi
      #Outputting number to choose from
      echo
      echo "0 - <quit>"
      # NOTE: making assumptions about the order of lines in each stanza!
 
      if [ "$num_images" -lt 40 ]; then
         #If less than 40 images
         display_images "0" "$num_images"
         #Displaying all of them
      else
         display_images "$min" "$max"
         #Otherwise display the requested selection of images, which to start with is 0-40
      fi
      

      echo
    fi
  if [ -f /mnt/stateful_partition/unencrypted/first_time ];then
  #If first time variable exists
    first_time=`cat /mnt/stateful_partition/unencrypted/first_time`
    #Reading first time variable
    if [ "$first_time" = "1" ];then
    #If NOT first time
      saved=`cat /mnt/stateful_partition/unencrypted/default_num`
      #Getting saved image number from last time
      prompt "Use image $saved (saved from last time)? 'y' (yes) or 'n' (no): "
      read multi
      #Reading user input
      if [ "$multi" = "y" ]; then
      #If user wants to load saved image
        num="$saved"
        #Setting image
      else
         if [ $max == "$num_images" ];then
            #If we're already showing to the maximum number of images
            min=0
            max=40
            #We should go from the start again
         elif [ $(( max + 40 )) -gt "$num_images" ];then
            #If there's less than 40 images left to show
            min=$(( min + 40 ))
            max="$num_images"
            #Showing the remaining images
         else
            min=$(( min + 40 ))
            max=$(( max + 40 ))
            #Otherwise, show the next 40 images
         fi
        prompt "Select the number of the recovery image to download (this will be saved for next time), or press M to see options $min to $max: "
	      read num
	      if [ "$num" = "m" ];then
	         continue
	         #Looping again from the start, with the new selection to display
	      else
	      if [ "$num" != "0" ]; then
	   #If user isn't quitting
	   echo "$num" > /mnt/stateful_partition/unencrypted/default_num
      #Saving option for next time
	    echo "1" > /mnt/stateful_partition/unencrypted/first_time
	    #Declaring that the program has been run
	   fi
	      fi
	      
	    fi
    else
      if [ $max == "$num_images" ];then
            #If we're already showing to the maximum number of images
            min=0
            max=40
            #We should go from the start again
         elif [ $(( max + 40 )) -gt "$num_images" ];then
            #If there's less than 40 images left to show
            min=$(( min + 40 ))
            max="$num_images"
            #Showing the remaining images
         else
            min=$(( min + 40 ))
            max=$(( max + 40 ))
            #Otherwise, show the next 40 images
         fi
      prompt "Select the number of the recovery image to download (this will be saved for next time), or press M to see options $min to $max: "
      read num
      #Reading user input
      if [ "$num" = "m" ] ; then
	      continue
	      #Looping again from the start, with the new selection to display
	   else
         if [ "$num" != "0" ]; then
   	   #If user isn't quitting
   	   echo "$num" > /mnt/stateful_partition/unencrypted/default_num
         #Saving option for next time
   	    echo "1" > /mnt/stateful_partition/unencrypted/first_time
   	    #Declaring that the program has been run
   	   fi
	    fi
    fi
  else
  if [ $max == "$num_images" ];then
            #If we're already showing to the maximum number of images
            min=0
            max=40
            #We should go from the start again
         elif [ $(( max + 40 )) -gt "$num_images" ];then
            #If there's less than 40 images left to show
            min=$(( min + 40 ))
            max="$num_images"
            #Showing the remaining images
         else
            min=$(( min + 40 ))
            max=$(( max + 40 ))
            #Otherwise, show the next 40 images
         fi
  prompt "Select the number of the recovery image to download (this will be saved for next time), or press M to see options $min to $max: "
      read num
      #Reading user input
      if [ "$num" = "m" ]; then
         #If we should display more options
	     continue
	     #Looping again from the start, with the new selection to display
	   else
   	   if [ "$num" != "0" ]; then
   	   #If user isn't quitting
   	   echo "$num" > /mnt/stateful_partition/unencrypted/default_num
         #Saving option for next time
   	    echo "1" > /mnt/stateful_partition/unencrypted/first_time
   	    #Declaring that the program has been run
   	   fi
      
	    fi
	fi
    if [ -z "$num" ] || [ "$num" = "?" ]; then
      show=yes
    elif echo "$num" | grep -q '[^0-9]'; then
      echo "Sorry, I didn't understand that."
    else
      if [ "$num" -lt "0" ] || [ "$num" -gt "$num_images" ]; then
        echo "That's not one of the choices."
      elif [ "$num" -eq 0 ]; then
        quit
      else
        break;
      fi
    fi
    #Verifying that number inputted is correct
  done
  echo

  # global
  user_choice="$num"
}

# Set the user's image choice automatically based on the $MODEL variable.
# On success, it sets the global variable 'user_choice' to the selected
# image number.
set_image() {
  local count
  local line
  local num

  # NOTE: making assumptions about the order of lines in each stanza!
  count=0
  while read line; do
    if echo "$line" | grep -q '^name='; then
      count=$(( count + 1 ))
    elif echo "$line" | grep -q "$MODEL"; then
      echo "Selecting image for model $MODEL"
      user_choice="$count"
      return
    fi
  done < "$config"

  # If we get here then recovery.conf didn't have a hwid that matched $MODEL
  echo "Sorry, there's no recovery image for Chrome Notebook: $MODEL."
  quit
}

# Fetch and verify the user's chosen image. On success, it sets the global
# variable 'image_file' to indicate the local name of the unpacked binary that
# should be written to the USB drive. It also sets the global variable
# 'disk_needed' to the minimum capacity of the USB drive required (in MB).
fetch_image() {
  local start
  local end
  local line
  local key
  local val
  local file
  local zipfilesize
  local filesize
  local url
  local md5
  local sha1
  local line_num
  local zipfile
  local err
  local sum

  file=
  zipfilesize=
  filesize=
  url=
  md5=
  sha1=
  line_num="0"

  # Convert image number to line numbers within config file.
  start=$(echo $start_lines | cut -d' ' -f$1)
  end=$(echo $end_lines | cut -d' ' -f$1)

  while read line; do
    # Skip to the start of the desired stanza
    line_num=$(( line_num + 1 ))
    if [ "$line_num" -lt "$start" ] || [ "$line_num" -ge "$end" ]; then
      continue;
    fi

    # Process the stanza.
    if [ -n "$line" ]; then
      key=${line%=*}
      val=${line#*=}
      if [ -z "$key" ] || [ -z "$val" ] || [ "$key=$val" != "$line" ]; then
        DEBUG "ignoring $line"
        continue
      fi

      case $key in
        # The descriptive stuff we'll just save for later.
        file)
          file="$val"
          ;;
        zipfilesize)
          zipfilesize="$val"
          ;;
        filesize)
          filesize="$val"
          ;;
        md5)
          md5="$val"
          ;;
        sha1)
          sha1="$val"
          ;;
        url)
          # Make sure we have enough temp space available. Die if we don't.
          verify_tmp_space $(roundup $(( $zipfilesize + $filesize )))
          # Try to download each url until one works.
          if [ -n "$url" ]; then
            # We've already got one (it's very nice).
            continue;
          fi
          warn "Downloading image zipfile from $val"
          warn ""
          zipfile=${val##*/}
          up_url=`cat /mnt/stateful_partition/unencrypted/update_url`
          if [ "$val" = "$up_url" ]; then
	          prompt "No update available. Would you like to change your image number? 'y' (yes, quit), 'n' (no, quit) or 'c' (update anyway)? : "
	          read change </dev/tty
		        if [ "$change" = "n" ]; then
	    	      exit
	          elif [ "$change" = "c" ]; then
	            echo "Updating..."
		        elif [ "$change" = "y" ]; then
		          echo "0" > /mnt/stateful_partition/unencrypted/first_time
		          echo "Please run this script again, and you will be able to choose your image number."
		         exit
		fi
          else
            echo "$val" > /mnt/stateful_partition/unencrypted/update_url
          fi
          if fetch_url "$val" "$zipfile" "resumeok"; then
            # Got it.
            url="$val"
          fi
          ;;
      esac
    fi
  done < "$config"

  if [ -z "$url" ]; then
    DEBUG "couldn't fetch zipfile"
    return 1
  fi

  # Verify the zipfile
  if ! ls -l "$zipfile" | grep -q "$zipfilesize"; then
    DEBUG "zipfilesize is wrong"
    return 1
  fi
  sum=$(compute_checksum "$zipfile")
  DEBUG "checksum is $sum"
  if [ "$CHECKTYPE" = "md5" ] && [ "$sum" != "$md5" ]; then
    DEBUG "wrong $CHECK"
    return 1
  elif [ "$CHECKTYPE" = "sha1" ] && [ "$sum" != "$sha1" ]; then
    DEBUG "wrong $CHECK"
    return 1
  fi

  # Unpack the file
  warn "Unpacking the zipfile"
  rm -f "$file"
  if [ "$DECOMPRESS" = "unzip" ]; then
    if ! unzip "$zipfile" "$file"; then
      DEBUG "Can't unpack the zipfile"
      return 1
    fi
  elif [ "$DECOMPRESS" = "zcat" ]; then
    if ! zcat "$zipfile" > "$file"; then
	  DEBUG "Can't unpack the zipfile"
	  return 1
	fi
  fi

  if ! ls -l "$file" | grep -q "$filesize"; then
    DEBUG "unpacked filesize is wrong"
    return 1
  fi

  # global
  image_file="$file"
  disk_needed=$(roundup "$filesize")
}

##############################################################################
# Helper functions to manage USB drives.

# Return a list of base device names ("sda sdb ...") for all USB drives
get_devlist() {
  local dev
  local t
  local r

  # Are we on a mac?
  if [ -n "$DISKUTIL" ]; then
    for dev in $(diskutil list | grep '^/dev'); do
      r=$(diskutil info $dev | grep 'Ejectable\: *Yes') || true
      t=$(diskutil info $dev | grep 'Protocol\: *USB') || true
      if [ "$r" != "" ]; then
        if [ "$t" != "" ]; then
          echo "$dev" | sed 's,/dev/,,'
        fi
      fi
    done
  else
    # No, linux, I hope
    for dev in $(cat /proc/partitions); do
      [ -r "/sys/block/$dev/device/type" ] &&
      t=$(cat "/sys/block/$dev/device/type") &&
      [ "$t" = "0" ] &&
      r=$(cat "/sys/block/$dev/removable") &&
      [ "$r" = "1" ] &&
      readlink -f "/sys/block/$dev" | grep -q -i usb &&
      echo "$dev" || true
    done
  fi
}

# Return the raw size in MB of each provided base device name ("sda sdb ...")
get_devsize() {
  local dev
  local bytes
  local sectors

  # Are we on a mac?
  if [ -n "$DISKUTIL" ]; then
    for dev in $1; do
      bytes=$(diskutil info $dev | \
        awk '/\([0-9]+ Bytes\)/' | sed -E 's/.*\(([0-9]+) Bytes\).*/\1/')
      echo $(( $bytes / 1024 / 1024))
    done
  else
    for dev in $1; do
      sectors=$(cat "/sys/block/$dev/size")
      echo $(( $sectors * 512 / 1024 / 1024 ))
    done
  fi
}


# Return descriptions for each provided base device name ("sda sdb ...")
get_devinfo() {
  local dev
  local v
  local m
  local s
  local ss

  # Are we on a mac?
  if [ -n "$DISKUTIL" ]; then
    for dev in $1; do
      m=$(diskutil info $dev | grep 'Device \/ Media Name\:' | \
          sed 's/^[^:]*: *//') || true
      s=$(diskutil info $dev | grep 'Total Size\:' | \
          sed 's/^[^:]*: *\([^(]*\).*/\1/') || true
      echo "/dev/$dev  $s $m"
    done
  else
    # No, linux, hopefully
    for dev in $1; do
      v=$(cat "/sys/block/$dev/device/vendor") &&
      m=$(cat "/sys/block/$dev/device/model") &&
      s=$(cat "/sys/block/$dev/size") && ss=$(( $s * 512 / 1000000 )) &&
      echo "/dev/$dev ${ss}MB $v $m"
    done
  fi
}

# Enumerate and descript the specified base device names ("sda sdb ...")
get_choices() {
  local dev
  local desc
  local count

  count=1
  echo "0 - <quit>"
  for dev in $1; do
    desc=$(get_devinfo "$dev")
    echo ""
    echo "$count - Use $desc"
    count=$(( count + 1 ))
  done
}

# Make the user pick a USB drive to write to. On success, it sets the global
# variable 'user_choice' to the selected device name ("sda", "sdb", etc.)
choose_drive() {
  local show
  local devlist
  local choices
  local num_drives
  local msg
  local num

  show=yes
  while true; do
    if [ -n "$show" ]; then
      devlist=$(get_devlist)
      choices=$(get_choices "$devlist")
      if [ -z "$devlist" ]; then
        num_drives="0"
        msg="I can't seem to find a valid USB drive."
      else
        num_drives=$(echo "$devlist" | wc -l)
        if [ "$num_drives" != "1" ]; then
          msg="I found $num_drives USB drives."
        else
          msg="I found $num_drives USB drive."
        fi
      fi
      echo "

$msg  We need one with at least ${disk_needed}MB capacity.

$choices

"
      show=
    fi
    prompt "Tell me what to do (or just press Enter to scan again): "
    read num
    if [ -z "$num" ] || [ "$num" = "?" ]; then
      show=yes
    elif echo "$num" | grep -q '[^0-9]'; then
      echo "Sorry, I didn't understand that."
    else
      if [ "$num" -lt "0" ] || [ "$num" -gt "$num_drives" ]; then
        echo "That's not one of the choices."
      elif [ "$num" -eq 0 ]; then
        quit
      else
        break;
      fi
    fi
  done

  # global
  user_choice=$(echo $devlist | cut -d' ' -f$num)
}

# Unmount a partition
unmount_partition() {
  if [ -n "$DISKUTIL" ]; then
    diskutil unmountDisk "$1" || ufatal "Unable to unmount $1."
  else
    umount "$1" || ufatal "Unable to unmount $1."
  fi
}

##############################################################################
# Okay, do something...

# Warn about usage
if [ -n "${1:-}" ] && [ "$1" != "--config" ]; then
  echo "This program takes no arguments. Just run it."
  # That's not really true. For debugging you can specify "--config URL".
  exit 1
fi

powerd_status="`initctl status powerd`"
if [ ! "$powerd_status" = "powerd stop/waiting" ]
then
  initctl stop powerd
fi

# Make sure we have the tools we need
require_utils

# Need a place to work. We prefer a fixed location so we can try to resume any
# interrupted downloads.
if [ -n "$WORKDIR" ]; then
  if [ ! -d "$WORKDIR" ] && ! mkdir "$WORKDIR" ; then
    warn "Using temporary directory"
    WORKDIR=
  fi
fi
if [ -z "$WORKDIR" ]; then
  WORKDIR=$(mktemp -d)
  # Clean up temporary directory afterwards
  trap "cd; rm -rf ${WORKDIR}" EXIT
fi

cd "$WORKDIR"
warn "Working in $WORKDIR/"
rm -f "$debug"

# Download the config file to see what choices we have.
warn "Downloading config file from $CONFIGURL"
fetch_url "$CONFIGURL" "$tmpfile" || \
  gfatal "Unable to download the config file"

# Separate the version info from the images
grep '^recovery_tool' "$tmpfile" > "$version"
grep -v '^#' "$tmpfile" | grep -v '^recovery_tool' > "$config"
# Add one empty line to the config file to terminate the last stanza
echo >> "$config"

# Make sure that the config file version matches this script version.
tmp=$(grep '^recovery_tool_linux_version=' "$version") || \
  tmp=$(grep '^recovery_tool_version=' "$version") || \
  gfatal "The config file doesn't contain a version string."
filevers=${tmp#*=}
if [ "$filevers" != "$MYVERSION" ]; then
  tmp=$(grep '^recovery_tool_update=' "$version");
  msg=${tmp#*=}
  warn "This tool is version $MYVERSION." \
    "The config file is for version $filevers."
  fatal ${msg:-Please download a matching version of the tool and try again.}
fi

# Check the config file to be sure it's valid. As a side-effect, this sets the
# global variable 'num_images' with the number of image stanzas read, but
# that's independent of whether the config is valid.
good_config || gfatal "The config file isn't valid."

# If the MODEL env variable was not preset, make the user pick an image to
# download, or exit.
if [ -z "$MODEL" ]; then
  choose_image
else
  set_image
fi
# Download the user's choice
fetch_image "$user_choice" || \
  gfatal "Unable to download a valid recovery image."

# Get start and size of our root partition
rootfs_start="`cgpt show -i 3 -n -b -q $image_file`"
rootfs_size="`cgpt show -i 3 -n -s -q $image_file`"
echo "RootFS Start: $rootfs_start  RootFS Size: $rootfs_size"

# Copy the Chrome OS kernel overtop the Chromium kernels. On recovery images
# Kern A is the recovery kernel, Kern B is what we want
if [ ! -d $WORKDIR/chrome_efi_mount ]
then
  mkdir $WORKDIR/chrome_efi_mount
fi
mount -ro loop,offset=$((`cgpt show -i 12 -n -b -q $image_file`*512)) $image_file $WORKDIR/chrome_efi_mount
if [ ! -d $WORKDIR/chromium_efi_mount ]
then
  mkdir $WORKDIR/chromium_efi_mount
fi
mount /dev/mmcblk0p12 $WORKDIR/chromium_efi_mount -t vfat
cp $WORKDIR/chrome_efi_mount/syslinux/vmlinuz.B $WORKDIR/chromium_efi_mount/syslinux/vmlinuz.B -f
cp $WORKDIR/chrome_efi_mount/syslinux/vmlinuz.B $WORKDIR/chromium_efi_mount/syslinux/vmlinuz.A -f
umount $WORKDIR/chrome_efi_mount
umount $WORKDIR/chromium_efi_mount

dd if=$image_file of=/dev/mmcblk0p3 bs=512 skip=$rootfs_start count=$rootfs_size


exit 0
