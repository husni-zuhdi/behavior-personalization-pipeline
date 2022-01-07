# To set default encoding to UTF-8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

if ( $args.Count -eq 0 ) {
    echo 'Please enter your bucket name as ./spindown_infra.sh your-bucket'
    exit 0
}

$AWS_ID=$(aws sts get-caller-identity --query Account --output text)
$AWS_REGION=$(aws configure get region)

$SERVICE_NAME="bp-batch-project"
$IAM_ROLE_NAME="bp-spectrum-redshift"

echo "Deleting bucket $args and its contents"
aws s3 rm s3://$args `
--recursive `
--output text >> teardown.log

aws s3api delete-bucket `
--bucket $args `
--output text >> teardown.log

echo "Deleting local data"
rm data.zip -Force
rm -r data -Force

echo "Spinning down local Airflow infrastructure"
docker compose down --volumes --rmi all

echo "Terminating EMR cluster $SERVICE_NAME"
$EMR_CLUSTER_ID=$(aws emr list-clusters --active --query "Clusters[?Name==`'$SERVICE_NAME'`].Id" --output text)

aws emr terminate-clusters `
--cluster-ids $EMR_CLUSTER_ID >> teardown.log

echo "Terminating Redshift cluster $SERVICE_NAME"
aws redshift delete-cluster `
--skip-final-cluster-snapshot `
--cluster-identifier $SERVICE_NAME `
--output text >> teardown.log

echo "Dissociating AmazonS3ReadOnlyAccess policy from $IAM_ROLE_NAME role"
aws iam detach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess `
--output text >> teardown.log
echo "Dissociating AWSGlueConsoleFullAccess policy from $IAM_ROLE_NAME role"
aws iam detach-role-policy `
--role-name $IAM_ROLE_NAME `
--policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess `
--output text >> teardown.log
echo "Deleting role $IAM_ROLE_NAME"
aws iam delete-role `
--role-name $IAM_ROLE_NAME `
--output text >> teardown.log

# rm -f teardown.log setup.log trust-policy.json