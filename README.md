# Deploy MediaWiki on AWS 


The scripts are to assist in deploying MediaWiki on AWS EC2 and RDS. Mediawiki deployment is done using Elastic Beanstalk.

The deployment scripts create a complete dedicated VPC, and RDS service, S3 storage and the deployment in Elastic Beanstalk (EB).

##Summary
In the VPC 4 subnets are created and spread over 2 Availability Zones. 2 subnets are public internet facing and will be used by Elastic Beanstalk to deploy the Load Balancer and the web server instance(s). 2 subnets are private and used for RDS to provision the MySQL database. The source code is uploaded to S3 as zip file, EB is able to use this zip file on S3 to deploy the application in the instances it creates.

See [Usage](#usage) to work with the scripts.


##Implementation considerations

### Language: BASH
The scripting language used is available on almost all UNIX, Linux and OS X hosts.
While BASH can be archaic and doesn’t result in more elegant code as e.g. Python, BASH is the universal screwdriver found everywhere ;-) 

Another motivation to use BASH is not to be dependent on any other 3rd party tools commonly used in bigger AWS environments (e.g. terraform). These scripts are meant for those who have a free-tier AWS account to set up a wiki quickly while maintaining full control over the Mediawiki source code for development of a custom version of MediaWiki instance.

One shortcoming of BASH is not being able to read JSON elegantly.
No surprise, BASH backdates JSON by about a decade. I have found that **`jq`** is the command line swiss army knife for JSON and reading basic values from even the most complex JSON is straightforward. See [Pre-requisites](#usage) how to install jq.

### Database
MediaWiki uses a LAMP stack (preferred) and I used the RDS service (single AZ) to provide the database layer to the web server(s). This means the database isn't running on the same instance as the web server, and allows to scale to multiple web servers using a single database. But more importantly you don't want to manage another database!

### Web Application Deployment
#### Elastic Beanstalk
- Due to the high level nature of the EB GUI, the (also high level) EB CLI are not completely in sync. And the EB CLI doesn’t provide all the functionality you find in the EB GUI. This asks for some creativity combining the EB CLI with the lower level interface to the EB API via the AWS CLI.

- The biggest challenge is that you have very little control (in the traditional sense) within the EC2 instances launched by EB. Which can be seen as good thing, as it forces the developer to abstract from the underlying LAMP stack. Parameters to PHP can be passed via the **EB environment variables**. This is what is used to drive some of the assignments of values in `LocalSettings.php`, the file in MediaWiki which drives the behaviour of the MediaWiki instance. In the real world it is highly recommended to put LocalSettings.php under source control as well. With these scripts **no** attempt was made to integrate with a version control environment, instead it packs up all the Mediawiki source in .zip file together with the parameter driven LocalSettings.php (provided). So EB environment variables can be used to pass values to MediaWiki.

- For easy of use all script parameters have defaults and many of them can be changed in interactive mode (no command line arguments). All relevant parameters are stored in `.conf` files, so they can be re-read in subsequent script runs and will have the latest value entered (when default value was not accepted with <return> key). I did it this way as it allowed for minimal BASH code to deal with the parameters, passing them via command  line becomes quickly quite messy.

## To Do

1. Session affinity

 In order for MediaWiki to work properly over multiple webservers the sticky bit in the Load Balancer needs to be set, see [here](http://docs.aws.amazon.com/elasticloadbalancing/latest/classic/elb-sticky-sessions.html). 
 
 The script should figure out which ELB instance the EB CLI has created and then apply the appropriate ELB API calls to set the sticky bit. 
 
 **_If you run a single web server this is not a concern._**

2. URL

 The URL for the wiki is the fully qualified domain name (e.g. `http://mywiki.us-east-1.elasticbeanstalk.com`) plus the directory of the version of the wiki in the source code (in this case mediawiki-1.27.3). The wiki URL is therefor:
`http://mywiki.us-east-1.elasticbeanstalk.com/mediawiki-1.27.3`. In many cases this is not the desired URL for public use. This involves additional DNS setup.


##Testing

The scripts were tested on **OS X** and on an **Amazon Linux AMI**, however the set up script for the MediaWiki deployment conveniently launches a browser to access MediaWiki from the script. This obviously doesn’t work on a remote server.
Other then that the scripts run fine on Linux as well, with the exception that SED works a bit different on Linux vs OS X (and the script handles this).

## <a name="usage"></a> Usage

### Pre-requisites

- For querying JSON output produced by the AWS CLI the BASH scripts use **`jq`**. 

 - Download from [here](https://stedolan.github.io/jq/download)

 - Use `sudo yum install jq` on an Amazon Linux AMI.

- This script for actual application deployment uses the high level CLI of Elastic Beanstalk to deploy and manage applications. 
This **EB CLI** is not by default installed on Linux AMIs.

 For installation of **EB CLI** see [here](http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/eb-cli3-install.html)


### Scripts
There is a total of 3 scripts to set up a complete environment to run MediaWiki:

1. **setup-vpc.sh**

 Build a Internet facing VPC with all the network plumbing. 
 Fairly straightforward set up of VPC:
 -  2 public internet facing subnets distributed over 2 Availability Zones
 - 2 private subnets distributed over 2 AZ for RDS use.
 - Generation of Key Pair (when Key Pair specified doesn't exists).

 All relevant configuration parameters have defaults but will be prompted in case other values are desired.
 
 The configuration parameters are saved in **`vpc.conf`** for reuse in subsequent runs.

1. **setup-db.sh**

 Creates a MySQL database for MediaWiki using RDS within the private subnets of the VPC.
 - After creating a DB subnet group using the private subnets it will create a MySQL database in RDS
 - By default the name of the database is related to the name of the application. This is why the name of the application is prompted, so the database name and database instance id can be generated based on the name.

 All relevant configuration parameters have defaults but will be prompted in case other values are desired.

 The configuration parameters are saved in **`db.conf`** for reuse in subsequent runs.


1. **setup-eb-wiki.sh**

 Will setup the EB environment with the mediawiki application and start deployment of MediaWiki for its database initialization and subsequent database access.


 - The script expects the full mediawiki source code distribution (potentially modified or enhanced) to be available and in a local directory. The root directory of the mediawiki code should contain the `'LocalSettings.php` as provided in this repo, as it has been crafted for this deployment on EB. 
    
 
 - The script also guides you to particular details of initializing the MediaWiki database in order for MediaWiki to work. If run on a local machine with access to a browser it will open a browser (tab) with the right MediaWiki page during the process. Information what to enter in the browser will be displayed in the terminal screen.
    
 All relevant configuration parameters have defaults but will be prompted in case other values are desired

 The configuration parameters are saved in **`eb.conf`** for reuse in subsequent runs

1. **delete-eb-wiki.sh**

 Terminates the complete application environment as found in `eb.conf`

1. **delete-db.sh**

 Deletes the RDS instance as found in `db.conf`

###MediaWiki notes:

1) To use the wiki point a browser to main page of the wiki at
`http://mywiki.us-east-1.elasticbeanstalk.com/mediawiki-1.27.3`. The directory name is the same name as the root directory name of the source code.
 Just entering the domain name will result in a permission error not having access to /  

2) When MediaWiki is started and the database hasn’t been properly initialized with the MediaWiki DB schema, you get the error message “A database query error has occurred. This may indicate a bug in the software.” Obviously this is not a bug in the software, unless you consider an inappropriate error message a bug :-)













