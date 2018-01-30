#!/bin/bash
#Author - Ratish Maruthiyodan
#Modified by - Kuldeep Kulkarni to add:
#1. bootstrap function for installing required openstack client packages.
#2. Fixed hostname issue
#3. Time tracking
#4. Fixed network selection pattern
#Purpose - Script to Create Instance based on the parameters received from cluster.props file
##########################################################
echo `date +%s` > /tmp/start_time
source $1 2>/dev/null

git_pull()
{
	printf "\n\n$(tput setaf 2)Checking if code is up-to-date else will pull latest code now\nSmart option for lazy people ;)\n$(tput sgr 0)"
	git pull
}

source_env()
{
	env_file=`ls -lrt $LOC/openstack_cli_support*|tail -1|awk '{print $9}'`
	source $env_file
	echo "$OS_USERNAME" > /tmp/user 
}

bootstrap_mac()
{
	printf "\nChecking for the required openstack client packages\n"
	ls -lrt $INSTALL_DIR/openstack >/dev/null 2>&1
	openstack_stat=$?
	ls -lrt $INSTALL_DIR/nova >/dev/null 2>&1
	nova_stat=$?
	ls -lrt $INSTALL_DIR/glance >/dev/null 2>&1
	glance_stat=$?
	ls -lrt $INSTALL_DIR/neutron >/dev/null 2>&1
	neutron_stat=$?

	if [ $openstack_stat -eq 0 ] && [ $nova_stat -eq 0 ] && [ $glance_stat -eq 0 ] && [ $neutron_stat -eq 0 ]
	then
		printf "Verified that required openstack client packages have been already installed!\nWe are good to go ahead :)"
	else
		printf "\nFound missing openstack client package(s)\nGoing ahead to install required client packages.. Enter Your Laptop's user password if prompted\n\n\nPress Enter to continue"
		read
		which brew | grep -q brew
		if [ "$?" -ne 0 ]
		then
			ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
		fi
		brew install python
		sudo pip install python-openstackclient
		sudo pip install python-novaclient
		sudo pip install python-neutronclient
	fi
}

find_image()
{
#       CENTOS_65="CentOS 6.5 (imported from old support cloud)"
#       CENTOS_6="CentOS 6.6 (Final)"
#       CENTOS_7="CentOS 7.0.1406"
#       UBUNTU_1204="Ubuntu 12.04"
#       UBUNTU_1404="Ubuntu 14.04"
#       SLES11SP3="SLES 11 SP3"

        glance image-list > /tmp/image_list
	if [ $? -ne 0 ]
	then
		echo -e "\nLooks like you have entered wrong password. Please run the script again & enter correct password."
		exit 1
	fi

	#If sandbox template is provided then go for sandbox image
	if [ "$SANDBOX_VERSION" != "" ]
	then
		image_id=`grep "$SANDBOX_VERSION" /tmp/image_list | cut -d "|" -f2,3 | xargs|cut -d'|' -f1|xargs`
	else 
		#If single/multi node template is provided then pick snapshot image if available or else go with standard OS image

	        grep "$OS"-hdp-"$CLUSTER_VERSION" /tmp/image_list
        	if [ $? -eq 0 ]
        	then
	                image_id=`cat /tmp/image_list | grep "$OS"-hdp-"$CLUSTER_VERSION" | cut -d "|" -f3 | xargs`
        	else
	                dt=$(date "+%Y-%m-%d-%H.%M")
        	        curl http://$REPO_SERVER/os_images.txt > /tmp/os_images_$dt.txt 2> /dev/null
                	source /tmp/os_images_$dt.txt

	                req_os_distro=$(echo $OS | awk -F"[0-9]" '{print $1}'| xargs| tr '[:lower:]' '[:upper:]')
        	        req_os_ver=$(echo $OS | awk -F"[a-z]" '{$1="";print $0}'|awk -F '.' '{print $1$2}'| xargs| tr '[:lower:]' '[:upper:]')
                	req_os_distro=$req_os_distro\_$req_os_ver
	                eval req_os_distro=\$$req_os_distro
        	        if [ -z "$req_os_distro" ]
                	then
                        	printf "\nThe mentioned OS image is unavailable. The available images are:\n"
	                        cat /tmp/os_images_$dt.txt
	                        rm -f /tmp/os_images_$dt.txt
        	                exit 1
                	fi

               		rm -f /tmp/os_images_$dt.txt
                	image_id=`cat /tmp/image_list | grep "$req_os_distro" | cut -d "|" -f2,3 | xargs|cut -d'|' -f1|xargs`
        	fi
	fi
	echo $image_id
}

find_netid()
{
	echo $(neutron net-list | grep PROVIDER_NET| cut -d"|" -f2 | xargs) 
}

find_flavor()
{
	nova flavor-list | grep -q "$FLAVOR_NAME"
	if [ $? -ne 0 ]
	then
		echo "Incorrect FLAVOR_NAME Set. The available flavors are:"
		nova flavor-list
		exit
	fi
	echo $FLAVOR_NAME

}


boot_clusternodes()
{
	for HOST in `grep -w 'HOST[0-9]*' $LOC/$CLUSTER_PROPERTIES|cut -d'=' -f2`
	{
		set -e
		echo "Creating Instance:  [ $HOST ]"
        	nova boot --image $IMAGE_NAME  --key-name $KEYPAIR_NAME  --flavor $FLAVOR --nic net-id=$NET_ID $OS_USERNAME-$HOST > /dev/null
		set +e
	}
}

check_for_duplicates()
{
	printf "\nChecking for duplicate hostnames... "
	existing_nodes=`nova list | awk -F '|' '{print $3}' | xargs`

	for HOST in `grep -w 'HOST[0-9]*' $LOC/$CLUSTER_PROPERTIES|cut -d'=' -f2`
        do
		echo $existing_nodes | grep -q -w $OS_USERNAME-$HOST
		if [ $? -eq 0 ]
		then
			printf "\n\nAn Instance with the name \"$OS_USERNAME-$HOST\" already exists. Please choose unique HostNames\n\n"
			exit 1
		fi
	done
	echo "  [ OK ]"
		
}

spin()
{
	count=$(($1*2))

	spin[0]="-"
	spin[1]="\\"
	spin[2]="|"
	spin[3]="/"

	for (( j=0 ; j<$count ; j++ ))
	do
	  for i in "${spin[@]}"
	  do
        	printf "\b$i"
	        sleep 0.12
  	  done
	done
}

check_vm_state()
{
	printf "\nWaiting for all the VMs to be started\n"
	STARTUP_STATE=0
	cat /dev/null > /tmp/opst-hosts
	STARTED_VMS=""
	for HOST in `grep -w 'HOST[0-9]*' $LOC/$CLUSTER_PROPERTIES|cut -d'=' -f2`
	do
		while [ $STARTUP_STATE -ne 1 ]
        	do
			echo "$STARTED_VMS" | grep -w -q $HOST
			if [ "$?" -ne 0 ]
			then
				vm_info=`nova show $OS_USERNAME-$HOST | egrep "vm_state|PROVIDER_NET network"`
				#echo $HOST ":" $vm_info
				echo $vm_info | grep -i -q -w 'active'
				if [ "$?" -ne 0 ]
				then
					STARTUP_STATE=0
					printf "\nThe VM ($HOST) is still in the State [`echo $vm_info | awk -F '|' '{print $3}'`]. Waiting for 5s... "
					spin 5
					continue
				fi
			else
				STARTUP_STATE=1
				break
			fi
			IP=`echo $vm_info | awk -F'|' '{print $6}' | xargs`
			echo $IP  $HOST.$DOMAIN_NAME $HOST $OS_USERNAME-$HOST.$DOMAIN_NAME >> /tmp/opst-hosts
			STARTUP_STATE=1
			STARTED_VMS=$STARTED_VMS:$HOST
			printf "\n$HOST Ok"
		done
		STARTUP_STATE=0
	done
}

populate_hostsfile()
{
	sort /tmp/opst-hosts | uniq > /tmp/opst-hosts1
	printf "\n\nUpdating /etc/hosts file.. \nEnter Your Laptop's user password if prompted\n"
	mod=0

	## checking if local /etc/hosts file already have existing entries for nodenames being added
	while read entry
	do
		fqdn=$(echo $entry | awk '{print $2}')
		grep -w -q $fqdn /etc/hosts
		if [ "$?" -eq 0 ]
		then
			if [ "$mod" -ne 1 ]
			then
			  printf "\n/etc/hosts file on the laptop already contains entry for '$fqdn'. Replacing the entries and backing up existing file in /tmp/hosts\n\n"
			  cp -f /etc/hosts /tmp/hosts
			  mod=1
			fi
			sudo sed -i.bak "s/[0-9]*.*$fqdn.*/$entry/" /etc/hosts
		else
			sudo sh -c "echo \#Ambari-"$AMBARIVERSION",HDP-"$CLUSTER_VERSION" >> /etc/hosts"
			sudo sh -c "echo $entry >> /etc/hosts"
		fi
	done < /tmp/opst-hosts1
	printf "\nInstances are created with the Following IPs:\n"	
	cat /tmp/opst-hosts1
}

## Start of Main

#set -x

if [ $# -ne 1 ] || [ ! -f $1 ];then
 echo "Insuffient or Incorrect Arguments"
 echo "Usage:: ./create_cluster.sh <cluster.props>"
 exit 1
fi

LOC=`pwd`
CLUSTER_PROPERTIES=$1
source $LOC/$CLUSTER_PROPERTIES 2>/dev/null
INSTALL_DIR=/usr/local/bin
git_pull
source_env
bootstrap_mac

printf "\n\nFinding the required Image\n"
IMAGE_NAME=$(find_image)
if [ "$?" -ne 0 ]
then
	printf "$IMAGE_NAME\n\n"
	exit 1
fi
echo "Selected Image:" $IMAGE_NAME
IMAGE_NAME=`echo $IMAGE_NAME| cut -d '|' -f2 | xargs`

FLAVOR=`find_flavor`
NET_ID=$(find_netid)
echo "Selected Network: $NET_ID"
echo "Selected Flavor: $FLAVOR"

check_for_duplicates
printf "\n--------------------------------------\n"
boot_clusternodes

check_vm_state
populate_hostsfile
printf "\n"

#If script is running with sandbox template then don't go ahead, quit.

if [ "$SANDBOX_VERSION" != "" ]
then
	end_time=`date +%s`
        start_time=`cat /tmp/start_time`
        runtime=`echo "($end_time-$start_time)/60"|bc -l`
	printf "\n\n$(tput setaf 2)$SANDBOX_VERSION is up and running!\n\nPlease note that it may take some time for ssh as services are still starting up.\n\nScript runtime(Including time taken for manual intervention) - $runtime minutes!\n$(tput sgr 0)" 
	exit 1
fi
sh $LOC/setup_cluster.sh $CLUSTER_PROPERTIES
