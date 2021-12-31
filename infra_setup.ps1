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
aws s3api create-bucket --bucket $args --create-bucket-configuration LocationConstraint=$AWS_REGION --output text >> setup.log

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