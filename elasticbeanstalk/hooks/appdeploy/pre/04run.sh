#!/bin/bash
#==============================================================================
# Copyright 2012 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Amazon Software License (the "License"). You may not use
# this file except in compliance with the License. A copy of the License is
# located at
#
#       http://aws.amazon.com/asl/
#
# or in the "license" file accompanying this file. This file is distributed on
# an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. See the License for the specific language governing permissions
# and limitations under the License.
#==============================================================================

. /opt/elasticbeanstalk/hooks/common.sh

EB_CONFIG_APP_CURRENT=$(/opt/elasticbeanstalk/bin/get-config container -k app_deploy_dir)
EB_CONFIG_DOCKER_LOG_HOST_DIR=$(/opt/elasticbeanstalk/bin/get-config container -k host_log_dir)
EB_CONFIG_DOCKER_STAGING_APP_FILE=$(/opt/elasticbeanstalk/bin/get-config container -k app_staging_file)
EB_CONFIG_DOCKER_PORT_FILE=$(/opt/elasticbeanstalk/bin/get-config container -k port_file)
EB_CONFIG_DOCKER_IMAGE_STAGING=$(/opt/elasticbeanstalk/bin/get-config container -k staging_image)
EB_SUPPORT_FILES=$(/opt/elasticbeanstalk/bin/get-config container -k support_files_dir)

# verify Dockerfile
# currently we require Dockerfile to expose exactly one port

EB_CONFIG_DOCKER_PORT=`cat $EB_CONFIG_APP_CURRENT/Dockerfile | grep -i ^EXPOSE | awk '{print $2}' | sed $'s/\r//'`

if [ -z "$EB_CONFIG_DOCKER_PORT" ]; then
	error_exit "No EXPOSE directive found in Dockerfile, abort deployment" 1
fi

if [ `echo $EB_CONFIG_DOCKER_PORT | wc -w` -gt 1 ]; then
	EB_CONFIG_DOCKER_PORT=`echo $EB_CONFIG_DOCKER_PORT | awk '{print $1}'`
	warn "Only one EXPOSE directive is allowed, using the first one: $EB_CONFIG_DOCKER_PORT"
fi

# Dockerrun.aws.json can override settings in Dockerfile

if [ -f $EB_CONFIG_APP_CURRENT/Dockerrun.aws.json ]; then
	EB_CONFIG_DOCKER_LOG_CONTAINER_DIR=`cat $EB_CONFIG_APP_CURRENT/Dockerrun.aws.json | jq -r .Logging`

	# get volume mounting points from Dockerrun.aws.json
	# this cannot be specified in Dockerfile since the host dir is host specific
	EB_CONFIG_DOCKER_VOLUME_MOUNTS=()

	while read -r VOLUME; do
		EB_CONFIG_DOCKER_VOLUME_MOUNTS+=(-v "$VOLUME")
	done < <(cat $EB_CONFIG_APP_CURRENT/Dockerrun.aws.json | jq -c '.Volumes[] | [.HostDirectory, .ContainerDirectory]' | sed -e 's/[]["]//g' -e 's/,/:/g')
fi

# mount the logs dir

if [ -n "$EB_CONFIG_DOCKER_LOG_CONTAINER_DIR" ] && [ "$EB_CONFIG_DOCKER_LOG_CONTAINER_DIR" != "null" ]; then
	EB_CONFIG_DOCKER_VOLUME_MOUNTS+=(-v "$EB_CONFIG_DOCKER_LOG_HOST_DIR:$EB_CONFIG_DOCKER_LOG_CONTAINER_DIR")
fi

# build --env arguments for docker from env var settings

EB_CONFIG_DOCKER_ENV_ARGS=()

while read -r ENV_VAR; do
	EB_CONFIG_DOCKER_ENV_ARGS+=(--env "$ENV_VAR")
done < <($EB_SUPPORT_FILES/generate_env)

# port mapping

echo $EB_CONFIG_DOCKER_PORT > $EB_CONFIG_DOCKER_PORT_FILE

# Command and Entrypoint
# ALL KINDS OF BASH CHARACTER ESCAPING MAGIC, DO NOT ATTEMPT TO EDIT

eval EB_CONFIG_DOCKER_COMMAND_ARGS=(`cat $EB_CONFIG_APP_CURRENT/Dockerrun.aws.json | jq -r .Command`)
[ "$EB_CONFIG_DOCKER_COMMAND_ARGS" = "null" ] && EB_CONFIG_DOCKER_COMMAND_ARGS=()

EB_CONFIG_DOCKER_ENTRYPOINT=`cat $EB_CONFIG_APP_CURRENT/Dockerrun.aws.json | jq -r .Entrypoint`
[ "$EB_CONFIG_DOCKER_ENTRYPOINT" = "null" ] && EB_CONFIG_DOCKER_ENTRYPOINT=
[ -n "$EB_CONFIG_DOCKER_ENTRYPOINT" ] && EB_CONFIG_DOCKER_ENTRYPOINT_ARGS=(--entrypoint "$EB_CONFIG_DOCKER_ENTRYPOINT")

# run the container

docker run -d \
		   "${EB_CONFIG_DOCKER_ENV_ARGS[@]}" \
		   "${EB_CONFIG_DOCKER_VOLUME_MOUNTS[@]}" \
		   "${EB_CONFIG_DOCKER_ENTRYPOINT_ARGS[@]}" \
		   $EB_CONFIG_DOCKER_IMAGE_STAGING \
		   "${EB_CONFIG_DOCKER_COMMAND_ARGS[@]}" 2>&1 | tee /tmp/docker_run.log | tee $EB_CONFIG_DOCKER_STAGING_APP_FILE

DOCKER_RUN_EXIT_CODE=${PIPESTATUS[0]}
if [ $DOCKER_RUN_EXIT_CODE -ne 0 ]; then
	LOG_TAIL=`cat /tmp/docker_run.log | tail -c 200`
	error_exit "Failed to run Docker container: $LOG_TAIL. Check snapshot logs for details." $DOCKER_RUN_EXIT_CODE
fi

# wait for 5 seconds then check if container is still up

sleep 5

EB_CONFIG_DOCKER_STAGING_APP=`cat $EB_CONFIG_DOCKER_STAGING_APP_FILE | cut -c 1-12`
if ! docker ps | grep -q $EB_CONFIG_DOCKER_STAGING_APP; then
	LOG_FILE=$EB_CONFIG_DOCKER_LOG_HOST_DIR/unexpected-quit.log

	echo "Docker container quit unexpectedly on `date`:" > $LOG_FILE
	docker logs $EB_CONFIG_DOCKER_STAGING_APP >> $LOG_FILE 2>&1
	LOG_TAIL=`cat $LOG_FILE | tail -c 200`

	error_exit "Docker container quit unexpectedly after launch: $LOG_TAIL. Check snapshot logs for details." 1
fi
