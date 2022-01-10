# To set default encoding to UTF-8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# Make sure bucket name parameter is inputed
if ($args.Count -eq 0) {
    echo 'Please enter your bucket name as ./setup_infra.sh your-bucket'
    exit 0
}
    
# Check if docker is curently running
if (!(docker info) 2>&1>$null) {
    echo "Docker does not seem to be running, run it first and retry"
    exit 1
}

# Setup the variables needed
$AWS_ID=$(aws sts get-caller-identity --query Account --output text)
$AWS_REGION=$(aws configure get region)

$SERVICE_NAME="bp-batch-project"
$IAM_ROLE_NAME="bp-spectrum-redshift"

$REDSHIFT_USER="bp_user"
$REDSHIFT_PASSWORD="bpP455wo0rd"
$REDSHIFT_PORT=5439
$EMR_NODE_TYPE="m4.xlarge"

echo "Creating bucket $args"
aws s3api create-bucket `
--bucket $args `
--create-bucket-configuration LocationConstraint=$AWS_REGION `
--output text >> setup.log

echo "Clean up stale local data"
rm data.zip -Force -ErrorAction SilentlyContinue    # This will cause error if data.zip not downloaded yet
rm data -r -Force -ErrorAction SilentlyContinue     # Ignore the error
rm __MACOSX -r -Force -ErrorAction SilentlyContinue

echo "Download data"
aws s3 cp s3://start-data-engg/data.zip ./
Expand-Archive data.zip .\

echo "Spinning up local Airflow infrastructure"
rm logs -r -Force -ErrorAction SilentlyContinue # This will cause error if logs and temp folder not created yet
rm temp -r -Force -ErrorAction SilentlyContinue # Ignore the error
mkdir logs
mkdir temp
docker compose up airflow-init
docker compose up -d

echo "Sleeping 5 Minutes to let Airflow containers reach a healthy state"
sleep 300

echo "Creating $SERVICE_NAME AWS EMR Cluster"
aws emr create-default-roles >> setup.log
aws emr create-cluster `
--applications Name=Hadoop Name=Spark `
--release-label emr-6.2.0 `
--name $SERVICE_NAME `
--scale-down-behavior TERMINATE_AT_TASK_COMPLETION `
--service-role EMR_DefaultRole `
--instance-groups '[{
        \"InstanceCount\": 1,
        \"EbsConfiguration\": {
            \"EbsBlockDeviceConfigs\": [
                {
                    \"VolumeSpecification\": {
                        \"SizeInGB\": 32,
                        \"VolumeType\": \"gp2\"
                    },
                    \"VolumesPerInstance\": 2
                }
            ]
        },
        \"InstanceGroupType\": \"MASTER\",
        \"InstanceType\": \"m4.xlarge\",
        \"Name\": \"Master - 1\"
    },
    {
        \"InstanceCount\": 2,
        \"BidPrice\": \"OnDemandPrice\",
        \"EbsConfiguration\": {
            \"EbsBlockDeviceConfigs\": [
                {
                    \"VolumeSpecification\": {
                        \"SizeInGB\": 32,
                        \"VolumeType\": \"gp2\"
                    },
                    \"VolumesPerInstance\": 2
                }
            ]
        },
        \"InstanceGroupType\": \"CORE\",
        \"InstanceType\": \"m4.xlarge\",
        \"Name\": \"Core - 2\"
    }]' >> setup.log

echo "Create role"
aws iam create-role --role-name $IAM_ROLE_NAME --assume-role-policy-document file://trust_policy.json --description 'spectrum access for redshift' >> setup.log

echo "Attach AmazonS3ReadOnlyAccess and AWSGlueConsoleFullAccess Policies to our IAM Role"
aws iam attach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess `
--output text >> setup.log
aws iam attach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess `
--output text >> setup.log

echo "Create $SERVICE_NAME AWS Redshift Cluster"
aws redshift create-cluster `
--cluster-identifier $SERVICE_NAME `
--node-type dc2.large `
--master-username $REDSHIFT_USER `
--master-user-password $REDSHIFT_PASSWORD `
--cluster-type single-node `
--publicly-accessible `
--iam-roles "arn:aws:iam::$(echo $AWS_ID):role/$IAM_ROLE_NAME" >> setup.log

while($true){
    echo "Waiting for Redshift cluster $SERVICE_NAME to start, sleeping for 60s before next check"
    sleep 60
    $REDSHIFT_CLUSTER_STATUS=$(aws redshift describe-clusters --cluster-identifier $SERVICE_NAME --query 'Clusters[0].ClusterStatus' --output text)
    if ("$REDSHIFT_CLUSTER_STATUS" -eq "available") {
        break
    }
}

$REDSHIFT_HOST=$(aws redshift describe-clusters --cluster-identifier $SERVICE_NAME --query 'Clusters[0].Endpoint.Address' --output text)

echo "Get REDSHIFT_SG_ID and set the new inbound rule"
$REDSHIFT_SG_ID=$(aws redshift describe-clusters --cluster-identifier $SERVICE_NAME --query 'Clusters[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text )
aws ec2 authorize-security-group-ingress `
--group-id $REDSHIFT_SG_ID `
--protocol all `
--cidr 0.0.0.0/0 >> setup.log

echo "Running setup script on redshift"
echo @"
CREATE EXTERNAL SCHEMA spectrum
    FROM DATA CATALOG
    DATABASE 'spectrumdb'
    iam_role 'arn:aws:iam::$(echo $AWS_ID):role/$(echo $IAM_ROLE_NAME)'
CREATE EXTERNAL DATABASE IF NOT EXISTS;
DROP TABLE IF EXISTS spectrum.user_purchase_staging;
CREATE EXTERNAL TABLE spectrum.user_purchase_staging (
    InvoiceNo VARCHAR(10),
    StockCode VARCHAR(20),
    detail VARCHAR(1000),
    Quantity INTEGER,
    InvoiceDate TIMESTAMP,
    UnitPrice DECIMAL(8, 3),
    customerid INTEGER,
    Country VARCHAR(20)
) PARTITIONED BY (insert_date DATE) 
ROW FORMAT DELIMITED 
FIELDS TERMINATED BY ',' 
STORED AS textfile 
LOCATION 's3://$args/stage/user_purchase/' 
TABLE PROPERTIES ('skip.header.line.count' = '1');
DROP TABLE IF EXISTS spectrum.classified_movie_review;
CREATE EXTERNAL TABLE spectrum.classified_movie_review (
    cid VARCHAR(100),
    positive_review boolean,
    insert_date VARCHAR(12)
) STORED AS PARQUET LOCATION 's3://$args/stage/movie_review/';
DROP TABLE IF EXISTS public.user_behavior_metric;
CREATE TABLE public.user_behavior_metric (
    customerid INTEGER,
    amount_spent DECIMAL(18, 5),
    review_score INTEGER,
    review_count INTEGER,
    insert_date DATE
);
"@ > ./redshift_setup.sql

psql -f ./redshift_setup.sql postgres://${REDSHIFT_USER}:${REDSHIFT_PASSWORD}@${REDSHIFT_HOST}:${REDSHIFT_PORT}/dev
# rm ./redshift_setup.sql

echo "adding redshift connections to Airflow connection param"
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow connections add 'redshift' --conn-type 'Postgres' --conn-login $REDSHIFT_USER --conn-password $REDSHIFT_PASSWORD --conn-host $REDSHIFT_HOST --conn-port $REDSHIFT_PORT --conn-schema 'dev'
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow connections add 'postgres_default' --conn-type 'Postgres' --conn-login 'airflow' --conn-password 'airflow' --conn-host 'localhost' --conn-port 5432 --conn-schema 'airflow'

echo "adding S3 bucket name to Airflow variables"
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow variables set BUCKET $args

echo "adding AWS Region to Airflow variables"
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow variables set AWS_DEFAULT_REGION $AWS_REGION

echo "adding EMR ID to Airflow variables"
$EMR_CLUSTER_ID=$(aws emr list-clusters --active --query "Clusters[?Name==`'$SERVICE_NAME'`].Id" --output text)
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow variables set EMR_ID $EMR_CLUSTER_ID

echo "Setting up AWS access for Airflow workers"
$AWS_ID=$(aws configure get aws_access_key_id)
$AWS_SECRET_KEY=$(aws configure get aws_secret_access_key)
$EXTRA="{`"region_name`":`"$AWS_REGION`"}"
docker exec -d "$($(Split-Path -Path $pwd -Leaf).ToLower())-airflow-webserver-1" airflow connections add 'aws_default' --conn-type 'aws' --conn-login $AWS_ID --conn-password $AWS_SECRET_KEY --conn-extra $EXTRA

echo "Successfully setup local Airflow containers, S3 bucket $args, EMR Cluster $SERVICE_NAME, redshift cluster $SERVICE_NAME, and added config to Airflow connections and variables"