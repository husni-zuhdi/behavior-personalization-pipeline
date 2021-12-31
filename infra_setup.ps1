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

# # Test number-0
# echo "Bucket name is $args"
# docker info
# # SUCCESS