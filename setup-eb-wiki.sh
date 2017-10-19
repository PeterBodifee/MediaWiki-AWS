#!/bin/bash

# Author  : Peter Bodifee
# Date    : 2017-09-17
# Version : 0.1

# this script uses jq 1.5 to parse JSON content. 
# see https://stedolan.github.io/jq/download/

# this script uses the eb cli. see http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html

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
    #is different on OS X and Linux
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

# get parameters from db configuration file
if [ -f db.conf ]
then    
    source db.conf
    if [ -z ${DBEndpointAddress} ]
    then
        echo "ERROR: No DB Endpoint Address in db.conf. Run create Database script first to fill db.conf"
        exit 1
    fi
else
    echo "ERROR: No db.conf found"
    exit 1
fi

# check if we have a eb configuration file, if not create the boilerplate
if [ -f eb.conf ]
then
    source eb.conf
else
    cat >eb.conf <<ENDOFCONTENT
ApplicationName=
ApllicationEnvironment=
FullyQualifiedCNAME=
SourceCodeBucket=
SourceCodeObject=
SourceCodeDirectory=
ENDOFCONTENT
fi

# parameters to be prompted
[ -z $ApplicationName ] && ApplicationName='mywiki'
 Prompt 'ApplicationName'

# make sure we have an application name as this will be part of other identifiers.
if [ -z "${ApplicationName}" ]
then
    echo "ERROR: ApplicationName can not be empty"
    exit 1
fi

[ -z $SourceCodeDirectory ] && SourceCodeDirectory='source/mediawiki-1.27.3'
 Prompt 'SourceCodeDirectory'

# make sure we have this directory and it is not empty
if [ "$(ls -A "${SourceCodeDirectory}" 2>/dev/null)" ]
then
    CurrentDir=$(pwd)
    cd ${SourceCodeDirectory}
    SourceCodeFullPath=$(pwd)
    SourceCodeDirBasename=$(basename ${SourceCodeFullPath})
    cd ${CurrentDir}
else
    echo "ERROR: No source code found at ${SourceCodeDirectory}"
    exit 1
fi 

echo "The following parameter will determine how many web servers for Mediawiki will be deployed"
echo "Since several steps need to be taken to initialize Mediawiki, suggestion is stay at 1(one)"
NrOfWebServers=1
 Prompt 'NrOfWebServers'

#remaining parameters

 Prompt 'Region'
 Prompt 'KeyPairName'
 Prompt 'VPC'
 Prompt 'VPCSecGroupID'
 Prompt 'PublicSubnetIDs'
 Prompt 'PrivateSubnetIDs'

[ -z $ApplicationEnvironment ] && ApplicationEnvironment="${ApplicationName}-dev"
 Prompt 'ApplicationEnvironment'

DatabaseMasterUsername='dbadmin'
DatabaseMasterPassword='dbpw1234'
 Prompt 'DatabaseMasterUsername'
 Prompt 'DatabaseMasterPassword'

# parameters assumed, can also be prompted if desired.

Platform="php-5.6"
DatabasePort='3306'

AccountAlias=$(aws iam list-account-aliases | jq -r .AccountAliases[])
SourceCodeBucket="${ApplicationName}-source-${Region}-${AccountAlias}"


#--------------------
echo '> check if the Application Enviroment is available in DNS'
#--------------------

Result=$(aws elasticbeanstalk check-dns-availability --cname-prefix ${ApplicationName})
if [ $(echo $Result | jq -r .Available) != 'true' ]
then
    echo "ERROR: ${ApplicationName} can not be used for ApplicationName, not available in EB DNS namespace"
    exit 1
else
    FullyQualifiedCNAME=$(echo $Result | jq -r .FullyQualifiedCNAME)
    WikiURL="http://${FullyQualifiedCNAME}/${SourceCodeDirBasename}" 
    echo "Wiki will be available on URL ${WikiURL}" 
fi

#--------------------
echo '> check if we have or can create the S3 bucket for the source code'
#--------------------

# check first if we have the bucket by listing potential objects in the bucket
Result=$(aws s3 ls s3://${SourceCodeBucket})
RC=$?
if [ $RC == 0 ]
then
    echo "Bucket ${SourceCodeBucket} exists."
else
    echo -n "Bucket ${SourceCodeBucket} will be created: "
    # make the bucket
    Result=$(aws s3 mb s3://${SourceCodeBucket})
    RC=$?
    if [ $RC == 0 ]
    then
        echo "Done."
    else
        echo "Failed (Result: $Result)"
        echo "ERROR: Bucket to store source code can not be created (return code: $RC)"
        exit 1
    fi
fi
    
#--------------------
echo '> initializing elasticbeanstalk application'
#--------------------

# starting with a clean slate, remove elasticbeanstalk config file in this directory
[ -f .elasticbeanstalk/config.yml ] && rm .elasticbeanstalk/config.yml

eb init ${ApplicationName} \
    --region ${Region} \
    --platform "${Platform}" \
    --keyname ${KeyPairName} \
    2>&1 | tee -a $LOG

RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: Initialization of Application in Elastic Beanstalk failed (return code: $RC)"
    exit 1
fi

#--------------------
echo '> creating elasticbeanstalk application environment with sample PHP app, do not press Ctrl-C'
#--------------------

eb create ${ApplicationEnvironment} \
    --region ${Region} \
    --cname ${ApplicationName} \
    --instance_type "t2.micro" \
    --sample \
    --elb-type classic  \
    --scale ${NrOfWebServers} \
    --no-verify-ssl  \
    --vpc.id  ${VPC} \
    --vpc.ec2subnets ${PublicSubnetIDs} \
    --vpc.elbsubnets ${PublicSubnetIDs} \
    --vpc.dbsubnets ${PrivateSubnetIDs} \
    --vpc.elbpublic \
    --vpc.publicip \
    --vpc.securitygroups ${VPCSecGroupID} \
    2>&1 | tee -a $LOG
    
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: Creation of Application Environment in Elastic Beanstalk failed (return code: $RC)"
    exit 1
fi


#--------------------
echo '> set the environment parameters for Mediawiki, do not press Ctrl-C'
#--------------------

eb use ${ApplicationEnvironment}
eb setenv --timeout 10 \
    MW_SCRIPTPATH=/${SourceCodeDirBasename} \
    MW_SERVER_URL=http://${FullyQualifiedCNAME} \
    MW_SITENAME=${ApplicationName} \
    RDS_DB_NAME=${DatabaseName} \
    RDS_HOSTNAME=${DBEndpointAddress} \
    RDS_PASSWORD=${DatabaseMasterPassword} \
    RDS_PORT=${DatabasePort} \
    RDS_USERNAME=${DatabaseMasterUsername} \
    2>&1 | tee -a $LOG
echo "Environment parameters set in Application Environment"

#--------------------
echo -n '> zip up the source code without LocalSettings.php'
#--------------------
cd ${SourceCodeFullPath}/..
SourceCodeRootDir=$(pwd)
zipFile=${ApplicationName}.zip
zip -q -r ${zipFile} ${SourceCodeDirBasename}/ 
# remove LocalSettings.php so we can use the Mediawiki initialisation process to fill the database with initial content
zip -q -d ${zipFile} ${SourceCodeDirBasename}/LocalSettings.php 
cd ${CurrentDir}
echo ' DONE'

#--------------------
echo '> upload the application source code to S3'
#--------------------
# make the S3 key for the sourcecode bundle unique by prefixing date and time
Now=$(date +%Y%m%d%H%M%S)
SourceCodeObject=${Now}-${zipFile}
aws s3 cp ${SourceCodeRootDir}/${zipFile} s3://${SourceCodeBucket}/${SourceCodeObject} \
    2>&1 | tee -a $LOG

#--------------------
echo '> deploying the initial application version v0, do not press Ctrl-C'
#--------------------
aws elasticbeanstalk create-application-version \
    --application-name ${ApplicationName} \
    --version-label "${ApplicationName} v0"  \
    --description "initial version of Mediawiki for database init" \
    --source-bundle S3Bucket="${SourceCodeBucket}",S3Key="${SourceCodeObject}" \
    2>&1 | tee -a $LOG

eb deploy --version "${ApplicationName} v0" \
    2>&1 | tee -a $LOG
echo "Application deployed"

#--------------------
echo '> run the mediawiki setup in the browser and continue this script when done'
#--------------------
echo "A browser session will open for the initial mediawiki database initialisation."
echo "If the database has been previously been initialized, this step can be skipped."
echo ""
echo "On Mediawiki Database Connect page use the following values:"
echo "    Database host     : $DBEndpointAddress"
echo "    Database name     : $DatabaseName "
echo "    Database username : $DatabaseMasterUsername"
echo "    Database password : $DatabaseMasterPassword"
echo ""
echo "On the Mediawiki Name setup page use the following values:"
echo "    Wiki name  : ${ApplicationName}"
echo "    Wiki admin : any username you can remember (this will be the account with mediawiki super user powers)"
echo "    Select the ' I'm bored already, just install the wiki.' option"
echo ""
echo "At the end of the Mediawiki setup the site will download a LocalSettings.php file, which can be ignored."
echo "This download contains hardcoded values, which will be replaced with the LocalSettings.php in this distribution"
echo "The site specific information is set up via PHP environment variables which will be set up in the EB environment."

open ${WikiURL}

read -n 1 -s -r -p "After Mediawiki database setup is completed press any key to continue"
echo " Continuing"

#--------------------
echo -n '> add the LocalSettings.php file with the environment variables to the zipped source code'
#--------------------
cd ${SourceCodeFullPath}/..
zip -q -u ${zipFile} ${SourceCodeDirBasename}/LocalSettings.php 
cd ${CurrentDir}
echo ' DONE'

#--------------------
echo '> upload the new zipped source code to S3'
#--------------------
# It is ok to overwrite the previous upload in S3, as we are just adding the one missing file in the source.
aws s3 cp ${SourceCodeRootDir}/${zipFile} s3://${SourceCodeBucket}/${SourceCodeObject} \
    2>&1 | tee -a $LOG

#--------------------
echo '> deploy the final first application version v1, do not press Ctrl-C'
#--------------------
aws elasticbeanstalk create-application-version \
    --application-name ${ApplicationName} \
    --version-label "${ApplicationName} v1"  \
    --description "first version of Mediawiki ready for use" \
    --source-bundle S3Bucket="${SourceCodeBucket}",S3Key="${SourceCodeObject}" \
    2>&1 | tee -a $LOG
eb deploy --version "${ApplicationName} v1" \
    2>&1 | tee -a $LOG
echo "Application deployed"


# set sticky session on load balancer, mediawiki is not completely stateless.
# TO DO

# save parameters in conf file
UpdateConfFile eb.conf ApplicationName        "${ApplicationName}"
UpdateConfFile eb.conf ApllicationEnvironment "${ApplicationEnvironment}"
UpdateConfFile eb.conf FullyQualifiedCNAME    "${FullyQualifiedCNAME}"
UpdateConfFile eb.conf SourceCodeBucket       "${SourceCodeBucket}"
UpdateConfFile eb.conf SourceCodeObject       "${SourceCodeObject}"
UpdateConfFile eb.conf SourceCodeDirectory    "${SourceCodeDirectory}"

#--------------------
echo '> starting the web application in the browser'
#--------------------
open ${WikiURL}

# this should be the last command of this script
echo '> end of script'; exit 0
