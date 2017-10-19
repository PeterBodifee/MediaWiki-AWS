#!/bin/bash

# Author  : Peter Bodifee
# Date    : 2017-09-17
# Version : 0.1

if [ -f db.conf ]
then
    source db.conf
else
    echo "ERROR: no db.conf found"
    exit 1
fi

#-------------------
echo "> deleting DB instance ${DatabaseInstanceID} "
#-------------------
Result=$(aws rds describe-db-instances \
                 --db-instance-identifier ${DatabaseInstanceID} \
                 2>&1)
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: $Result"
    exit 1
fi

# we know it exists, go delete
aws rds delete-db-instance \
        --db-instance-identifier ${DatabaseInstanceID} \
        --skip-final-snapshot \
        >/dev/null

# wait until the db instance is truly gone
Status=$(aws rds describe-db-instances \
                 --db-instance-identifier ${DatabaseInstanceID} \
                 --query DBInstances[*].DBInstanceStatus --output=text \
                 2>&1)
RC=$?
if [ $RC == 0 ]  
then
    #loop  while the database is being deleted.
    while [ "$Status" == 'deleting' ]
    do
        # wait 10 seconds before checking again
        sleep 10 

        Status=$(aws rds describe-db-instances \
                         --db-instance-identifier ${DatabaseInstanceID} \
                         --query DBInstances[*].DBInstanceStatus \
                         --output=text 2>&1)
        RC=$?
    done
    if [ $RC != 0 ]
    then
        echo "DB instance has been deleted"
    fi
else
    # something went not normal while describing the instance
    echo "INFO: $Status."
    echo "Assuming we can proceed"
fi

#-------------------
echo "> deleting DB subnet group ${DatabaseSubnetGroup}  "
#-------------------
aws rds delete-db-subnet-group \
        --db-subnet-group-name ${DatabaseSubnetGroup} 
