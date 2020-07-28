#!/bin/bash -e

export AWS_DEFAULT_OUTPUT=text

create_stack() {
  local stack_name=${1}
  local template_name=${2}
  local ResourcePrefix=${3}

  local ResourcePrefix_lowercase=$(echo ${ResourcePrefix} | tr '[:upper:]' '[:lower:]')
  
  aws cloudformation create-stack --stack-name ${stack_name} --template-body file://${template_name} --parameters ParameterKey=ResourcePrefix,ParameterValue=${ResourcePrefix} ParameterKey=ResourcePrefixLowercase,ParameterValue=${ResourcePrefix_lowercase} --capabilities CAPABILITY_NAMED_IAM --no-enable-termination-protection; aws cloudformation wait stack-create-complete --stack-name ${stack_name}
}

clone_and_commit() {
  local stack_name=${1}

  local repo_http_url=$(aws cloudformation describe-stacks --stack-name ${stack_name} --query 'Stacks[].Outputs[?OutputKey==`RepoHttpUrl`].OutputValue')

  git init .; git remote add origin ${repo_http_url}

  git add *; git commit -m "first commit"; git push --set-upstream origin master
}

wait_for_pipeline() {
  local pipeline_name=${1}
  local commit_id=${2}

  local message="Max attempts reached. Pipeline execution failed for commit: ${commit_id}"
  for i in {1..60}; do

    stage_status=$(aws codepipeline list-pipeline-executions --pipeline-name ${pipeline_name} --query 'pipelineExecutionSummaries[?sourceRevisions[0].revisionId==`'${commit_id}'`].status')

    if [ "${stage_status}" == "InProgress" ] || [ -z "${stage_status}" ]; then
      printf '.'
      sleep 30
    elif [ "${stage_status}" == "Succeeded" ]; then
      message="Pipeline execution succeeded for commit: ${commit_id}"
      break
    elif [ "${stage_status}" == "Failed" ]; then
      message="Pipeline execution Failed for commit: ${commit_id}"
      break
    fi

  done
  printf "\n${message}\n"
}

copy_test_data() {
  local artifact_bucket=${1}
  local artifact_key_prefix=${2}
  local pipe_stackname=${3}

  local data_lake_bucket=$(aws cloudformation describe-stacks --stack-name ${pipe_stackname} --query 'Stacks[].Outputs[?OutputKey==`DataLakeBucket`].OutputValue' --output text)

  aws s3 cp s3://${artifact_bucket}/${artifact_key_prefix}/annotation/clinvar/clinvar.vcf.gz s3://${data_lake_bucket}/annotation/clinvar/clinvar.vcf.gz
  aws s3 cp s3://${artifact_bucket}/${artifact_key_prefix}/annotation/clinvar/clinvar.annotated.vcf.gz s3://${data_lake_bucket}/annotation/clinvar/clinvar.annotated.vcf.gz
  aws s3 cp s3://${artifact_bucket}/${artifact_key_prefix}/annotation/clinvar/clinvar_conflicting.csv s3://${data_lake_bucket}/annotation/clinvar/conflicting/clinvar_conflicting.csv
}

setup() {

  local resource_prefix=$1
  local artifact_bucket=$2
  local artifact_key_prefix=$3

  local dir_prefix="GenomicsLearning"

  local zone_dir="${dir_prefix}Zone"
  local pipe_dir="${dir_prefix}Pipe"
  local code_dir="${dir_prefix}Code"

  local zone_stackname=${resource_prefix}-LandingZone
  local pipe_stackname=${resource_prefix}-Pipeline

  # Create stacks
  create_stack "${zone_stackname}" "${zone_dir}/zone_cfn.yml" "${resource_prefix}"
  create_stack "${pipe_stackname}" "${pipe_dir}/pipe_cfn.yml" "${resource_prefix}"

  # Clone and commit resources
  cd "${pipe_dir}"; clone_and_commit "${zone_stackname}"; cd ..
  cd "${code_dir}"; clone_and_commit "${pipe_stackname}";

  # Get the last commit id
  commit_id=$(git log -1 --pretty=format:%H)
  cd ..

  # Get pipeline name
  pipeline_name=$(aws cloudformation describe-stack-resource --stack-name ${pipe_stackname} --logical-resource-id CodePipeline --query 'StackResourceDetail.PhysicalResourceId')

  # Wait for pipeline execution using commit id
  wait_for_pipeline "${pipeline_name}" "${commit_id}"

  # Copy Test Data
  copy_test_data "${artifact_bucket}" "${artifact_key_prefix}" "${pipe_stackname}"

  # Run Test
  "${code_dir}/awscli_test.sh" "${resource_prefix}"
}

project_name=${PROJECT_NAME:-GenomicsLearning}

setup "$project_name" "${ARTIFACT_BUCKET}" "${ARTIFACT_KEY_PREFIX}"
