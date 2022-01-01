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

# # Test number-0 : Argument and docker
# echo "Bucket name is $args"
# docker info
# # SUCCESS

$AWS_ID=$(aws sts get-caller-identity --query Account --output text)
$AWS_REGION=$(aws configure get region)

$SERVICE_NAME="bp-batch-project"
$IAM_ROLE="bp-spectrum-redshift"

$REDSHIFT_USER="bp_user"
$REDSHIFT_PASSWORD="bpp455wo0rd"
$REDSHIFT_PORT=5439
$EMR_NODE_TYPE="m4.xlarge"

echo "Creating bucker $args"
aws s3api create-bucket `
--bucket $args `
--create-bucket-configuration LocationConstraint=$AWS_REGION `
--output text >> setup.log

echo "Clean up stale local data"
rm data.zip -Force
rm data -r -Force

echo "Download data"
aws s3 cp s3://start-data-engg/data.zip ./
Expand-Archive data.zip .\

echo "Spinning up local Airflow infrastructure"
rm logs -r -Force
mkdir logs
rm temp -r -Force
mkdir temp
docker compose up airflow-init
docker compose up -d

echo "Sleeping 5 Minutes to let Airflow containers reach a healthy state"
sleep 300

# # Test number-1 : Constant
# echo $AWS_ID
# echo $AWS_REGION
# # SUCCESS

echo "Creating $SERVICE_NAME AWS EMR Cluster"
aws emr create-default-roles >> setup.log
aws emr create-cluster `
--applications Name=Hadoop Name=Spark `
--release-label emr-6.2.0 `
--name $SERVICE_NAME `
--scale-down-behavior TERMINATE_AT_TASK_COMPLETION `
--service-role EMR_DefaultRole `
--instance-groups @"
[
    {
        "InstanceCount": 1,
        "EbsConfiguration": {
            "EbsBlockDeviceConfigs": [
                {
                    "VolumeSpecification": {
                        "SizeInGB": 32,
                        "VolumeType": "gp2"
                    },
                    "VolumePerInstance": 2
                }
            ]
        },
        "InstanceGroupType": "MASTER",
        "InstanceType": $EMR_NODE_TYPE,
        "Name": "Master - 1"
    },
    {
        "InstanceCount": 2,
        "BidPrice": "OnDemandPrice",
        "EbsConfiguration": {
            "EbsBlockDeviceConfigs": [
                {
                    "VolumeSpecification": {
                        "SizeInGB": 32,
                        "VolumeType": "gp2"
                    },
                    "VolumePerInstance": 2
                }
            ]
        },
        "InstanceGroupType": "CORE",
        "InstanceType": $EMR_NODE_TYPE,
        "Name": "Core - 2"
    }
]
"@ >> setup.log

echo "Create trust policy for AWS IAM role"
echo @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "redshift.amazonaws.com"
            },
            "Action": "sts.AssumeRole"
        }
    ]
}
"@ > trust-policy.json

echo "Create role"
aws iam create-role `
--role-name $IAM_ROLE_NAME `
--assume-role-policy-document file://trust-policy.json `
--description 'spectrum access for redshift' >> setup.log

echo "Attach AmazonS3ReadOnlyAccess and AWSGlueConsoleFullAccess Policies to our IAM Role"
aws iam attach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arm:aws:iam:aws:policy/AmazonS3ReadOnlyAccess `
--output text >> setup.log
aws iam attach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arm:aws:iam:aws:policy/AWSGlueConsoleFullAccess `
--output text >> setup.log

