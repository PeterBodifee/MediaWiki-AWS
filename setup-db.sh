#!/bin/bash

# Author  : Peter Bodifee
# Date    : 2017-09-17
# Version : 0.1

# this script uses jq 1.5 to parse JSON content. 
# see https://stedolan.github.io/jq/download/

# set up clean log file for output of major steps in this script
LOG=$0.log
[ -f $LOG ] && rm $LOG

function Prompt()
{
    # read from keyboard a value for the variable passed as argument
    # show the existing value of the variable between brackets []
    # when nothing is entered keep the original value
    read -p "$1 [${!1}]: " inputval
    if [ -z "${inputval}" ] 
    then
        eval $1=${!1}
    else
        eval $1=${inputval}
    fi
}

function UpdateConfFile () {

    # sed implementation for updating a file in place (-i option) 
    # is different on OS X and Linux
    [ $(uname) == 'Darwin' ] && sed -i '' -e 's!'$2'=.*!'$2'="'"$3"'"!' $1
    [ $(uname) == 'Linux' ] && sed -i 's!'$2'=.*!'$2'="'"$3"'"!' $1

}

# get parameters from vpc configuration file
if [ -f vpc.conf ]
then    
    source vpc.conf
else
    echo "ERROR: no vpc.conf found"
    exit 1
fi

# check if we have a db configuration file, if not create the boilerplate
if [ -f db.conf ]
then
    source db.conf
else
    cat >db.conf <<ENDOFCONTENT
DBEndpointAddress=
DatabaseName=
DatabaseInstanceID=
DatabasePort=
DatabaseSubnetGroup=
ENDOFCONTENT
fi

# check if there is an existing eb.conf file, then use it
[ -f eb.conf ] && source eb.conf

# parameters to be prompted
[ -z $ApplicationName ] && ApplicationName='mywiki'
 Prompt 'ApplicationName'

# make sure we have an application name 
# as this will be part of other identifiers.
if [ -z "${ApplicationName}" ]
then
    echo "ERROR: ApplicationName can not be empty"
    exit 1
fi
    
#remaining parameters

[ -z $ApplicationEnvironment ] && \
     ApplicationEnvironment="${ApplicationName}-dev"
[ -z $DatabaseInstanceID ] && \
    DatabaseInstanceID="${ApplicationEnvironment}-db"
# strip any non alphanumeric characters, i
# as they are not allowed for the db name.
[ -z $DatabaseName ] && \
    DatabaseName="${ApplicationEnvironment//[^[:alnum:]]/}db"    
[ -z $DatabasePort ] && DatabasePort='3306'

 Prompt 'ApplicationEnvironment'
 Prompt 'DatabaseInstanceID'
 Prompt 'DatabaseName'
 Prompt 'DatabasePort'

echo "> Make note of the following values as they are not stored"
echo "> in config file and needed later for application initialization"
DatabaseMasterUsername='dbadmin'
DatabaseMasterPassword='dbpw1234'
 Prompt 'DatabaseMasterUsername'
 Prompt 'DatabaseMasterPassword'

# parameters assumed, can also be prompted if desired.

DatabaseInstanceClass='db.t2.micro'
DatabaseEngine='mysql'
DatabaseEngineVersion='5.7.17'
LicenseModel='general-public-license'
StorageType='gp2'
AllocatedStorage='5'

echo "--- The following parameters will be used for database deployment --"
echo 'VPC                   : ' ${VPC}
echo 'ApplicationName       : ' ${ApplicationName}
echo 'ApplicationEnvironment: ' ${ApplicationEnvironment}
echo 'DatabaseInstanceID    : ' ${DatabaseInstanceID}
echo 'DatabaseName          : ' ${DatabaseName}
echo 'DatabaseMasterUsername: ' ${DatabaseMasterUsername}
echo 'PrivateSubnetIDs      : ' ${PrivateSubnetIDs}
echo "--------------------------------------------------------------------"


#------------------
echo -n '> create Security group for database access '
#------------------
# which should allow TCP inbound traffic on the DatabasePort 
# for now use standard default Sec Group of VPC. 
# DB is on private subnets and won't be accessible on the Internet
echo "[Using ${VPCSecGroupID}]"

#------------------
echo -n '> create db subnet group '
#------------------
# database subnetgroup are based on private subnets 
echo "[Using ${PrivateSubnetIDs}]"

DatabaseSubnetGroup="${ApplicationEnvironment}-db-subnet-gp"

# database subnetgroup is using private subnets, 
# so database is not directly accessible from internet 

# The command line option for subnet ids in create-db-subnet-group appears to be broken. 
# Using a JSON file for the input to the create-db-subnet-group command 

# create PrivateSubnetIDs in JSON format
subnets=$(echo ${PrivateSubnetIDs} | sed 's/,/ /g')
# JSON begin array symbol
SubnetsJSON='['          
for s in $subnets
do
    # add value as quoted string and comma delimeter
    SubnetsJSON=$SubnetsJSON'"'$s'",'   
done
# get length of String so we can remove the last comma
len=${#SubnetsJSON}                     
# remove last command and JSON end array symbol
SubnetsJSON=${SubnetsJSON:0:$len-1}']'  

# write content to json file for db subnet group creation.
cat >subnet-gp.json <<ENDOFCONTENT
{
    "DBSubnetGroupName": "${DatabaseSubnetGroup}", 
    "DBSubnetGroupDescription": "db subnet grp for ${ApplicationEnvironment}", 
    "SubnetIds": ${SubnetsJSON},  
    "Tags": [
        {   
            "Key": "Environment", 
            "Value": "${ApplicationEnvironment}"
        }   
    ]   
}
ENDOFCONTENT

# create db subnet group with json file as input
aws rds create-db-subnet-group \
    --cli-input-json file://$(pwd)/subnet-gp.json \
    2>&1 >$LOG


RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: Create db subnet group using file subnet-gp.json failed (return code: $RC), exiting $0"
    exit 1
else
    echo "DB subnet group ${DatabaseSubnetGroup} created"
    rm subnet-gp.json
fi

#------------------
echo -n '> create the RDS database instance '
#------------------
echo "[${DatabaseInstanceID}]"
aws rds create-db-instance	\
	--db-instance-class ${DatabaseInstanceClass}	\
	--engine ${DatabaseEngine}	\
	--db-instance-identifier ${DatabaseInstanceID} 	\
	--db-name ${DatabaseName} 	\
	--master-username ${DatabaseMasterUsername}	\
	--master-user-password ${DatabaseMasterPassword} 	\
	--db-subnet-group-name ${DatabaseSubnetGroup}	\
    --vpc-security-group-ids ${VPCSecGroupID}	\
	--engine-version ${DatabaseEngineVersion}	\
	--storage-type ${StorageType}	\
	--allocated-storage ${AllocatedStorage}	\
    --port ${DatabasePort}	\
	--license-model ${LicenseModel} 	\
    --no-multi-az 	\
	--no-publicly-accessible \
    2>&1 >$LOG


# The following options for create-db-instance are not used, assumed default values.
#   --db-security-groups } 	<value> \
#   --tags <value>	\
#	--preferred-maintenance-window <value>	\
#	--option-group-name <value>	\
#	--character-set-name <value>	\
#	--backup-retention-period <value>	\
#	--preferred-backup-window <value>	\
#	--db-cluster-identifier <value>	\
#	--db-parameter-group-name <value>	\
#	--auto-minor-version-upgrade | --no-auto-minor-version-upgrade	\
#	--availability-zone <value>       # can not be set when MultiAZ	\
#	--iops <value>	\
#	--tde-credential-arn <value>	\
#	--tde-credential-password <value>	\
#	--storage-encrypted | --no-storage-encrypted	\
#	--kms-key-id <value>	\
#	--domain <value>	\
#	--copy-tags-to-snapshot | --no-copy-tags-to-snapshot	\
#	--monitoring-interval <value>	\
#	--monitoring-role-arn <value>	\
#	--domain-iam-role-name <value>	\
#	--promotion-tier <value>	\
#	--timezone <value>	\
#	--enable-iam-database-authentication | --no-enable-iam-database-authentication	\

RC=$?
if [ $RC != 0 ]
then
    echo "Creating db instance failed (return code: $RC), exiting $0"
    exit 1
else
    echo "DB instance is being created, this can take a few minutes"
fi

#------------------
echo '> retrieving Endpoint address of DB instance'
#------------------
# loop until we have a DB Endpoint Adress
DBEndpointAddress=''
while [ -z ${DBEndpointAddress} ] 
do
    # wait 10 sec before checking, database need to be running first.
    sleep 10  

    aws rds describe-db-instances \
        --db-instance-identifier ${DatabaseInstanceID} \
        >db-instance.json

    # search for Endpoint Address in JSON output, 
    # return empty string if not found.
    DBEndpointAddress=$(jq -r '.DBInstances[].Endpoint.Address // empty' <db-instance.json)
done
rm db-instance.json

echo "DB Endpoint Address: ${DBEndpointAddress}"
# save addres in conf file
UpdateConfFile db.conf DBEndpointAddress "${DBEndpointAddress}" 
UpdateConfFile db.conf DatabaseName "${DatabaseName}" 
UpdateConfFile db.conf DatabaseInstanceID "${DatabaseInstanceID}" 
UpdateConfFile db.conf DatabasePort "${DatabasePort}" 
UpdateConfFile db.conf DatabaseSubnetGroup "${DatabaseSubnetGroup}"



# this should be the last command of this script
echo '> end of script'; exit 0
