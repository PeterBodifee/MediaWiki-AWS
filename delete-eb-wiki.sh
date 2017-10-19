#!/bin/bash

# Author  : Peter Bodifee
# Date    : 2017-09-17
# Version : 0.1

if [ -f eb.conf ]
then
    source eb.conf
else
    echo "ERROR: no eb.conf found"
    exit 1
fi

eb terminate $ApplicationEnvironment --all
