#!/usr/bin/env bash

morningstart=$1
lunchbreak=$2 # lunch break in minutes (optional)
fulldayinseconds=29520 # 8.2 hours in seconds
defaultbreaktime=1800 # 30 minutes in seconds

if [ -z "$morningstart" ]; then
    echo "Usage: $0 <morning_start_time> [lunch_break_in_minutes]"
    exit 1
fi

if [ -z "$lunchbreak" ]; then
    timetogo=$(($(date -d "$morningstart" '+%s') + $fulldayinseconds + $defaultbreaktime))
else
    timetogo=$(($(date -d "$morningstart" '+%s') + $fulldayinseconds + ($lunchbreak * 60)))
fi

date -d "@$timetogo" '+%H:%M'
