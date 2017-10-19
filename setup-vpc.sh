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

function UpdateConfFile () 
{
    # sed implementation for updating a file in place (-i option) 
    # is different on OS X and Linux
    
    [ $(uname) == 'Darwin' ] && sed -i '' -e 's!'$2'=.*!'$2'="'"$3"'"!' $1
    [ $(uname) == 'Linux' ] && sed -i 's!'$2'=.*!'$2'="'"$3"'"!' $1
}

# check if we have a vpc configuration file, if not create the boilerplate
if [ -f vpc.conf ]
then
    source vpc.conf
else
    cat >vpc.conf <<ENDOFCONTENT
AccountAlias=
Region=
VPC=
VPCSecGroupID=
PublicSubnetIDs=
PrivateSubnetIDs=
KeyPairName=
ENDOFCONTENT
fi

# parameters to be prompted
[ -z $Region ] && Region='us-east-1' ;
 Prompt Region

[ -z $AccountAlias ] && AccountAlias=$(aws iam list-account-aliases | jq -r .AccountAliases[]) ;
 Prompt AccountAlias

[ -z $KeyPairName ] && KeyPairName='MyKeyPair' ;
 Prompt KeyPairName

#remaining parameters
CidrBlockVPC=172.30.0.0/16
SubnetCIDR=(172.30.0.0/24 172.30.1.0/24 172.30.2.0/24 172.30.3.0/24)
SubnetAZ=(${Region}a ${Region}b ${Region}a ${Region}b)

#------------------
echo "> creating VPC with CIDR block $CidrBlockVPC"
#------------------

Result=$(aws ec2 create-vpc \
                 --cidr-block $CidrBlockVPC)
RC=$?
if [ $RC != 0 ]
then
    echo "Create VPC failed (return code: $RC), exiting $0"
    exit 1
fi
VPC=$(echo $Result | jq -r .Vpc.VpcId)

echo "VPC $VPC created, waiting for it to be available"

while [ "${VpcState}" != "available" ]
do
    sleep 3
    VpcState=$(aws ec2 describe-vpcs \
                       --vpc-id $VPC \
                       --query 'Vpcs[*].State' \
                       --output=text)
done

echo "VPC $VPC is now available"

#------------------
echo "> creating 2 public subnets in VPC"
#------------------

# public subnets are index 0, 1 in arrays
for i in 0 1
do
    # create subnet
    Result=$(aws ec2 create-subnet \
                     --vpc-id $VPC \
                     --cidr-block ${SubnetCIDR[$i]} \
                     --availability-zone ${SubnetAZ[$i]})
    RC=$?
    if [ $RC != 0 ]
    then
        echo "ERROR: creating subnet with CIDR ${SubnetCIDR[$i]} in AZ ${SubnetAZ[$i]} failed, exiting"
        exit 2
    else
        SubnetID[$i]=$(echo $Result | jq -r .Subnet.SubnetId)
    fi
done
PublicSubnetIDs="${SubnetID[0]},${SubnetID[1]}"

# create internet gateway
Result=$(aws ec2 create-internet-gateway) 
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: creating internet gateway failed"
    exit 3
else
    InternetGatewayID=$(echo $Result | jq -r .InternetGateway.InternetGatewayId)
fi
# attach internet gateway to VPC
Result=$(aws ec2 attach-internet-gateway \
                 --vpc-id $VPC \
                 --internet-gateway-id $InternetGatewayID)
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: attaching internet gateway $InternetGatewayID failed"
    exit 4
fi 

# create route table for public subnets
Result=$(aws ec2 create-route-table \
                 --vpc-id $VPC)
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: creating route table failed"
    exit 5
else
    RouteTableID=$(echo $Result | jq -r .RouteTable.RouteTableId)
fi 

# add internet gateway to route table
Result=$(aws ec2 create-route \
                 --route-table-id $RouteTableID \
                 --destination-cidr-block 0.0.0.0/0 \
                 --gateway-id $InternetGatewayID)
RC=$?
if [ $RC != 0 ]
then
    echo "ERROR: adding internet gateway $InternetGatewayID to route table $RouteTableID failed"
    exit 6
fi

# associate route table with public subnets
for i in 0 1
do
    Result=$(aws ec2 associate-route-table \
                     --subnet-id ${SubnetID[$i]} \
                     --route-table-id $RouteTableID)
	if [ $RC != 0 ]
	then
	    echo "ERROR: associating route table $RouteTableID to subnet ${SubnetID[$i]} failed"
	    exit 7
	fi
done

echo "Public Subnets created : $PublicSubnetIDs"

#------------------
echo "> creating 2 private subnets in VPC"
#------------------

# private subnets are index 2, 3 
for i in 2 3
do
    # create subnet
    Result=$(aws ec2 create-subnet \
                     --vpc-id $VPC \
                     --cidr-block ${SubnetCIDR[$i]} \
                     --availability-zone ${SubnetAZ[$i]})
    RC=$?
    if [ $RC != 0 ]
    then
        echo "ERROR: creating subnet with CIDR ${SubnetCIDR[$i]} in AZ ${SubnetAZ[$i]} failed, exiting"
        exit 2
    else
        SubnetID[$i]=$(echo $Result | jq -r .Subnet.SubnetId)
    fi
done
PrivateSubnetIDs="${SubnetID[2]},${SubnetID[3]}"

echo "Private Subnets created : $PrivateSubnetIDs"


#------------------
echo "> creating a Key Pair for SSH access to instances running the application"
#------------------
# check if we already have this key pair.
Result=$(aws ec2 describe-key-pairs \
                 --key-name $KeyPairName \
                 2>/dev/null)
RC=$?
if [ $RC == 0 ]
then
    echo "INFO: Key Pair $KeyPairName already exists, not generating a new one"
else
	# generate a new key pair
    # delete local file first
    [ -f ${KeyPairName}.pem ] && rm -f ${keyPairName}.pem
	Result=$(aws ec2 create-key-pair \
                     --key-name $KeyPairName \
                     --query 'KeyMaterial' \
                     --output text >${KeyPairName}.pem \
                     2>errors)
	RC=$?
    if [ $RC != 0 ]
	then
	    cat errors
	    echo "ERROR: creating Key Pair $KeyPairName failed"
	    exit 8
	fi
    # delete the file with potential error messages
    rm errors
	# only the owner should be able to read the file with the Key Pair
	chmod 400 ${KeyPairName}.pem
    echo "File ${KeyPairName}.pem with Key Pair created."
fi

 
#------------------
# get the default security group of this VPC as we will use this for RDS and Elastic Beanstalk
# we are assuming there are no special needs for additional security within the VPC
#------------------
Result=$(aws ec2 describe-security-groups \
                 --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values='default'")
if [ $RC != 0 ]
then
    echo "ERROR: reading the security groups in VPC $VPC"
    exit 10
fi
VPCSecGroupID=$(echo $Result | jq -r .SecurityGroups[].GroupId)

#------------------
# update configuration file with pertinent values
#------------------

UpdateConfFile vpc.conf VPC "$VPC"
UpdateConfFile vpc.conf AccountAlias "${AccountAlias}"
UpdateConfFile vpc.conf Region "${Region}"
UpdateConfFile vpc.conf VPC "${VPC}"
UpdateConfFile vpc.conf VPCSecGroupID "${VPCSecGroupID}"
UpdateConfFile vpc.conf PublicSubnetIDs "${PublicSubnetIDs}"
UpdateConfFile vpc.conf PrivateSubnetIDs "${PrivateSubnetIDs}"
UpdateConfFile vpc.conf KeyPairName "${KeyPairName}"

# this should be the last command of this script
echo '> end of script'; exit 0
