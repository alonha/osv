#!/bin/sh
#
#  Copyright (C) 2013 Cloudius Systems, Ltd.
#
#  This work is open source software, licensed under the terms of the
#  BSD license as described in the LICENSE file in the top-level directory.
#

PARAM_HELP="--help"
PARAM_PRIVATE_ONLY="--private-ami-only"
PARAM_INSTANCE="--instance-only"

print_help() {
 cat <<HLPEND

This script is intended to release OSv versions to Amazon EC2 service.
To start release process run "git checkout [options] <commit to be released> && $0"
from top of OSv source tree.

This script requires following Amazon credentials to be provided via environment variables:

    AWS_ACCESS_KEY_ID=<Access key ID>
    AWS_SECRET_ACCESS_KEY<Secret access key>

    See http://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSGettingStartedGuide/AWSCredentials.html
    for more details

    EC2_PRIVATE_KEY=<Location of EC2 private key file>
    EC2_CERT=<Location of EC2 certificate file>

    See http://docs.aws.amazon.com/AWSSecurityCredentials/1.0/AboutAWSCredentials.html#X509Credentials
    for more details

This script assumes following packages are installed and functional:

    1. Amazon EC2 API Tools (http://aws.amazon.com/developertools/351)

       Installation and configuration instructions available at:
       http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/SettingUp_CommandLine.html

    2. AWS Command Line Interface (http://aws.amazon.com/cli/)

       On Linux may be installed via pip:
       pip install awscli

This script receives following command line arguments:

    $PARAM_HELP - print this help screen and exit
    $PARAM_PRIVATE_ONLY - do not publish or replicate AMI - useful for pre-release build verification
    $PARAM_INSTANCE - do not rebuild, upload existing image and stop afer instance creation - useful for development phase

HLPEND
}

timestamp() {
 echo `date -u +'%Y-%m-%dT%H-%M-%SZ'`
}

OSV_VER=$(`dirname $0`/osv-version.sh)
OSV_RSTATUS=rstatus-$OSV_VER-`timestamp`.txt
OSV_BUCKET=osv-$OSV_VER-$USER-at-`hostname`-`timestamp`

EC2_CREDENTIALS="-o $AWS_ACCESS_KEY_ID -w $AWS_SECRET_ACCESS_KEY"
S3_CREDENTIALS="-O $AWS_ACCESS_KEY_ID -W $AWS_SECRET_ACCESS_KEY"

export AWS_DEFAULT_REGION=us-east-1
OSV_INITIAL_ZONE="${AWS_DEFAULT_REGION}a"

OSV_VOLUME=build/release/usr.img

#We use Microsoft Windows Server 2012 Base AMI by Amazon as a template
TEMPLATE_AMI_ID=ami-173d747e

amend_rstatus() {
 echo \[`timestamp`\] $* >> $OSV_RSTATUS
}

handle_error() {
 echo "\033[31m >>> [`timestamp`] ERROR: $* \033[0m"
 echo
 amend_rstatus ERROR: $*
 amend_rstatus Release FAILED.
}

echo_progress() {
 echo "\033[33m >>> $* \033[0m"
}

get_json_value() {
 python -c "import json,sys;obj=json.load(sys.stdin);print obj$*"
}

ec2_response_value() {
 local ROWID=$1
 local KEY=$2
 grep $ROWID | sed -n "s/^.*$KEY\s\+\(\S\+\).*$/\1/p"
}

import_osv_volume() {
 $EC2_HOME/bin/ec2-import-volume $OSV_VOLUME \
                                 -f raw \
                                 -b $OSV_BUCKET \
                                 -z $OSV_INITIAL_ZONE \
                                 $EC2_CREDENTIALS \
                                 $S3_CREDENTIALS | tee /dev/tty | ec2_response_value IMPORTVOLUME TaskId
}

get_volume_conversion_status() {
 local TASKID=$1
 $EC2_HOME/bin/ec2-describe-conversion-tasks $TASKID | tee /dev/tty | ec2_response_value IMPORTVOLUME Status
}

get_created_volume_id() {
 local TASKID=$1
 $EC2_HOME/bin/ec2-describe-conversion-tasks $TASKID | tee /dev/tty | ec2_response_value DISKIMAGE VolumeId
}

rename_object() {
 local OBJID=$1
 local OBJNAME=$2
 $EC2_HOME/bin/ec2-create-tags $OBJID --tag Name="$OBJNAME"
}

wait_import_completion() {
 local TASKID=$1
 local STATUS="unknown"

 while test x"$STATUS" != x"completed"
 do
   sleep 10
   STATUS=`get_volume_conversion_status $TASKID`
   echo Task is $STATUS
 done
}

launch_template_instance() {
 $EC2_HOME/bin/ec2-run-instances $TEMPLATE_AMI_ID --availability-zone $OSV_INITIAL_ZONE | tee /dev/tty | ec2_response_value INSTANCE INSTANCE
}

get_instance_state() {
 local INSTANCE_ID=$1
 aws ec2 describe-instances --instance-ids $INSTANCE_ID | get_json_value '["Reservations"][0]["Instances"][0]["State"]["Name"]'
}

get_instance_volume_id() {
 local INSTANCE_ID=$1
 aws ec2 describe-instances --instance-ids $INSTANCE_ID | get_json_value '["Reservations"][0]["Instances"][0]["BlockDeviceMappings"][0]["Ebs"]["VolumeId"]'
}

get_volume_state() {
 local VOLUME_ID=$1
 aws ec2 describe-volumes --volume-ids $VOLUME_ID | get_json_value '["Volumes"][0]["State"]'
}

get_ami_state() {
 local AMI_ID=$1
 aws ec2 describe-images --image-ids $AMI_ID | get_json_value '["Images"][0]["State"]'
}

detach_volume() {
 local VOLUME_ID=$1
 aws ec2 detach-volume --volume-id $VOLUME_ID --force
}

attach_volume() {
 local VOLUME_ID=$1
 local INSTANCE_ID=$2

 aws ec2 attach-volume --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device /dev/sda1
}

delete_volume() {
 local VOLUME_ID=$1
 aws ec2 delete-volume --volume-id $VOLUME_ID
}

delete_instance() {
 local INSTANCE_ID=$1
 aws ec2 terminate-instances --instance-ids $INSTANCE_ID
}

wait_for_instance_state() {
 local INSTANCE_ID=$1
 local REQUESTED_STATE=$2

 local STATE="unknown"

 while test x"$STATE" != x"$REQUESTED_STATE"
 do
   sleep 5
   STATE=`get_instance_state $INSTANCE_ID`
   echo Instance is $STATE
 done
}

wait_for_instance_startup() {
 wait_for_instance_state $1 running
}

wait_for_instance_shutdown() {
 wait_for_instance_state $1 stopped
}

wait_for_volume_state() {
 local VOLUME_ID=$1
 local REQUESTED_STATE=$2

 local STATE="unknown"

 while test x"$STATE" != x"$REQUESTED_STATE"
 do
   sleep 5
   STATE=`get_volume_state $VOLUME_ID`
   echo Volume is $STATE
 done
}

wait_for_ami_ready() {
 local AMI_ID=$1

 local STATE="unknown"

 while test x"$STATE" != x"available"
 do
   sleep 5
   STATE=`get_ami_state $AMI_ID`
   echo AMI is $STATE
 done
}

wait_for_volume_detach() {
 wait_for_volume_state $1 available
}

wait_for_volume_attach() {
 wait_for_volume_state $1 in-use
}

stop_instance_forcibly() {
 $EC2_HOME/bin/ec2-stop-instances $1 --force
}

create_ami_by_instance() {
 local INSTANCE_ID=$1
 local VERSION=$2
 aws ec2 create-image --instance-id $INSTANCE_ID --name OSv-$VERSION --description "Cloudius OSv demo $VERSION" | get_json_value '["ImageId"]'
}

copy_ami_to_region() {
 local AMI_ID=$1
 local REGION=$2

 aws ec2 --region $REGION copy-image --source-region $AWS_DEFAULT_REGION --source-image-id $AMI_ID | get_json_value '["ImageId"]'
}

make_ami_public() {
 local AMI_ID=$1
 $EC2_HOME/bin/ec2-modify-image-attribute $AMI_ID --launch-permission --add all
}

list_additional_regions() {
 $EC2_HOME/bin/ec2-describe-regions | ec2_response_value REGION REGION | grep -v $AWS_DEFAULT_REGION
}

replicate_ami() {
 local AMI_ID=$1
 local REGIONS="`list_additional_regions`"

 for REGION in $REGIONS
 do
     echo Copying to $REGION
     local AMI_IN_REGION=`copy_ami_to_region $AMI_ID $REGION`

     if test x"$AMI_IN_REGION" = x; then
         handle_error Failed to replicate AMI to $REGION region.
         return 1;
     fi

     amend_rstatus AMI ID in region $REGION is $AMI_IN_REGION
 done

 return 0;
}

if test x"$1" = x"$PARAM_HELP"; then
    print_help
    exit 0
fi

if test x"$1" = x"$PARAM_PRIVATE_ONLY"; then
    DONT_PUBLISH=1
fi

if test x"$1" = x"$PARAM_INSTANCE"; then
    INSTANCE_ONLY=1
fi

BUCKET_CREATED=0

while true; do

    echo_progress Releasing version $OSV_VER
    amend_rstatus Release status for version $OSV_VER

    if test x"$INSTANCE_ONLY" != x"1"; then
        echo_progress Building from the scratch
        make clean && git submodule update && make external && make img_format=raw

        if test x"$?" != x"0"; then
            handle_error Build failed.
            break;
        fi
    fi

    echo_progress Creating bucket $OSV_BUCKET
    aws s3api create-bucket --bucket $OSV_BUCKET

    if test x"$?" != x"0"; then
        handle_error Failed to create S3 bucket.
        break;
    fi

    BUCKET_CREATED=1

    echo_progress Importing volume $OSV_VOLUME
    IMPORT_TASK=`import_osv_volume`

    if test x"$IMPORT_TASK" = x; then
        handle_error Failed to import OSv volume.
        break;
    fi

    echo Import volume task ID is $IMPORT_TASK

    echo_progress Waiting for conversion tasks to complete
    wait_import_completion $IMPORT_TASK

    echo_progress Reading newly created volume ID
    VOLUME_ID=`get_created_volume_id $IMPORT_TASK`

    if test x"$VOLUME_ID" = x; then
        handle_error Failed to read created volume ID.
        break;
    fi

    echo Created volume ID is $VOLUME_ID

    echo_progress Renaming newly created volume OSv-$OSV_VER
    rename_object $VOLUME_ID OSv-$OSV_VER

    if test x"$?" != x"0"; then
        handle_error Failed to rename the new volume.
        break;
    fi

    echo_progress Creating new template instance from Windows AMI $TEMPLATE_AMI_ID
    INSTANCE_ID=`launch_template_instance`

    if test x"$INSTANCE_ID" = x; then
        handle_error Failed to create template instance.
        break;
    fi

    echo New instance ID is $INSTANCE_ID

    echo_progress Wait for instance to become running
    wait_for_instance_startup $INSTANCE_ID

    echo_progress Renaming newly created instance OSv-$OSV_VER
    rename_object $INSTANCE_ID OSv-$OSV_VER

    if test x"$?" != x"0"; then
        handle_error Failed to rename template instance.
        break;
    fi

    echo_progress Stopping newly created instance
    stop_instance_forcibly $INSTANCE_ID

    if test x"$?" != x"0"; then
        handle_error Failed to stop template instance.
        break;
    fi

    echo_progress Waiting for instance to become stopped
    wait_for_instance_shutdown $INSTANCE_ID

    echo_progress Replacing template instance volume with uploaded OSv volume
    ORIGINAL_VOLUME_ID=`get_instance_volume_id $INSTANCE_ID`

    if test x"$ORIGINAL_VOLUME_ID" = x""; then
        handle_error Failed to read original volume ID.
        break;
    fi

    echo Original volume ID is $ORIGINAL_VOLUME_ID

    echo_progress Detaching template instance volume
    detach_volume $ORIGINAL_VOLUME_ID

    if test x"$?" != x"0"; then
        handle_error Failed to detach original volume from template instance.
        break;
    fi

    echo_progress Waiting for volume to become available
    wait_for_volume_detach $ORIGINAL_VOLUME_ID

    echo_progress Attaching uploaded volume to template instance
    attach_volume $VOLUME_ID $INSTANCE_ID

    if test x"$?" != x"0"; then
        handle_error Failed to attach OSv volume to template instance.
        break;
    fi

    echo_progress Waiting for uploaded volume to become attached
    wait_for_volume_attach $VOLUME_ID

    if test x"$INSTANCE_ONLY" = x"1"; then
        amend_rstatus Development instance $INSTANCE_ID created successfully.
        break;
    fi

    echo_progress Creating AMI from resulting instance
    AMI_ID=`create_ami_by_instance $INSTANCE_ID $OSV_VER`
    echo AMI ID is $AMI_ID

    if test x"$AMI_ID" = x""; then
        handle_error Failed to create AMI from template instance.
        break;
    fi

    amend_rstatus AMI ID in region $AWS_DEFAULT_REGION is $AMI_ID

    echo Waiting for AMI to become availabe
    wait_for_ami_ready $AMI_ID

    if test x"$DONT_PUBLISH" = x"1"; then
        amend_rstatus Private AMI created successfully.
        break;
    fi

    echo_progress Making AMI public
    make_ami_public $AMI_ID

    if test x"$?" != x"0"; then
        handle_error Failed to publish OSv AMI.
        break;
    fi

    echo_progress Replicating AMI to existing regions
    replicate_ami $AMI_ID

    if test x"$?" != x"0"; then
        handle_error Failed to initiate AMI replication. Replicate $AMI_ID in $AWS_DEFAULT_REGION region manually.
        break;
    fi

    amend_rstatus Release SUCCEEDED

break

done

echo_progress Cleaning-up intermediate objects

if test x"$INSTANCE_ONLY" != x"1"; then

    if test x"$VOLUME_ID" != x""; then
        echo_progress Detaching imported OSv volume
        detach_volume $VOLUME_ID

        echo_progress Wait for imported OSv volume to become detached
        wait_for_volume_detach $VOLUME_ID

        echo_progress Deleting imported OSv volume
        delete_volume $VOLUME_ID
    fi

    if test x"$INSTANCE_ID" != x""; then
        echo_progress Deleting template instance
        delete_instance $INSTANCE_ID
    fi

fi

if test x"$ORIGINAL_VOLUME_ID" != x""; then
    echo_progress Deleting template instance volume
    delete_volume $ORIGINAL_VOLUME_ID
fi

if test x"$BUCKET_CREATED" != x"0"; then
    echo_progress Deleting bucket $OSV_BUCKET
    aws s3 rb s3://$OSV_BUCKET --force
fi

echo_progress Done. Release status is stored in $OSV_RSTATUS:
cat $OSV_RSTATUS
