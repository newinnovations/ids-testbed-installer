#!/bin/bash

# Control script for IDSA IDS-Testbed
#
# Martin van der Werff (martin.vanderwerff (at) tno.nl)
#
# Compatible with commit 4e651853149f13c02cec88710134a416bcb23f53 (Wed Feb 16 17:03:10 2022 +0100)

function usage() {
	echo
	echo "d888888b d8b   db  .d88b."
	echo "\`~~88~~' 888o  88 .8P  Y8."
	echo "   88    88V8o 88 88    88   Netherlands Organisation for Applied Scientific Research"
	echo "   88    88 V8o88 88    88"
	echo "   88    88  V888 \`8b  d8'               IDSA TESTBED CONTROL SCRIPT"
	echo "   YP    VP   V8P  \`Y88P'"
	echo
	echo "Usage:"
	echo
	echo "  ./testbed.sh [options] start|stop|clean"
	echo
	echo
	echo "  start (default)"
	echo
	echo "    Builds testbed component docker images (when not available) and starts testbed"
	echo
	echo "    -r --install-requirements  install required ubuntu packages"
	echo "    -t --test                  run tests"
	echo
	echo
	echo "  stop"
	echo
	echo "    Stops testbed"
	echo
	echo
	echo "  clean"
	echo
	echo "    Stops testbed (when running) and removes all testbed component images"
	echo
	echo "    -p --prune                 removes all your unused docker images"
	echo
}

export TB_GIT="${HOME}/IDS-testbed"
export PWD="$(dirname $(readlink -f $0))"
export TB_COUNTRY=NL
export TB_ORGANIZATION=TNO

export TB_NETWORK=broker-localhost_default

INSTALL_REQUIREMENTS=0
TEST=0
CLEAN_PRUNE=0
OPERATION=start

while [[ $# -gt 0 ]]; do
	case $1 in
		-r|--install-requirements)
			INSTALL_REQUIREMENTS=1
			shift
			;;
		-t|--test)
			TEST=1
			shift
			;;
		-p|--prune)
			CLEAN_PRUNE=1
			shift
			;;
		start|stop|clean)
			OPERATION="$1"
			shift
			;;
		-*|--*)
			echo "Unknown option $1"
			usage
			exit 1
			;;
		*)
			echo "Unknown operation $1"
			usage
			exit 1
			;;
	esac
done

echo "--------------------------------------------------------"
echo "INSTALL REQUIREMENTS = ${INSTALL_REQUIREMENTS}"
echo "TEST                 = ${TEST}"
echo "PRUNE                = ${CLEAN_PRUNE}"
echo "OPERATION            = ${OPERATION}"
echo "--------------------------------------------------------"

function run() {
	INSTANCE="$1"
	IMAGE="$2"
	TITLE="$3"
	COMMAND="$4"
	if [ ! "$(docker ps -q -f name=${INSTANCE})" ]; then
		if [ "$(docker ps -aq -f name=${INSTANCE})" ]; then
			echo "Removing stale ${TITLE}"
			docker rm ${INSTANCE} > /dev/null
		fi
		echo "Starting ${TITLE}"
		gnome-terminal --title "${TITLE}" -- sh -c "docker run --name ${INSTANCE} ${COMMAND} --network=${TB_NETWORK} ${IMAGE}"
	else
		echo "${TITLE} already running"
	fi
}

function client_id() {
	local CERT="$(openssl x509 -in "${TB_GIT}/CertificateAuthority/data/cert/$1.crt" -text)"
	local SKI="$(echo "$CERT" | grep -A1 "Subject Key Identifier" | tail -n 1 | tr -d ' ')"
	local AKI="$(echo "$CERT" | grep -A1 "Authority Key Identifier" | tail -n 1 | tr -d ' ')"
	echo "$SKI:$AKI"
}

function test_daps() {
	CLIENT_NAME="$1"
	CLIENT_ID=$(client_id "$CLIENT_NAME")
	echo
	echo "Testing DAPS by requesting DAT for ${CLIENT_NAME}"
	echo "-- ID = ${CLIENT_ID}"
	JWT="$(ruby /dev/stdin <<EOF
require 'openssl'
require 'jwt'
require 'json'
CLIENTNAME = "$CLIENT_NAME"
CLIENTID = "$CLIENT_ID"
# Only for debugging!
filename = "$TB_GIT/CertificateAuthority/data/cert/$CLIENT_NAME.key"
client_rsa_key = OpenSSL::PKey::RSA.new File.read(filename)
payload = {
  'iss' => CLIENTID,
  'sub' => CLIENTID,
  'exp' => Time.new.to_i + 3600,
  'nbf' => Time.new.to_i,
  'iat' => Time.new.to_i,
  'aud' => 'idsc:IDS_CONNECTORS_ALL'
}
token = JWT.encode payload, client_rsa_key, 'RS256'
puts token
EOF
)"
	#echo "-- JWT=$JWT"

	FROM_DAPS="$(curl -Ss localhost:4567/token --data "grant_type=client_credentials&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=${JWT}&scope=idsc:IDS_CONNECTOR_ATTRIBUTES_ALL")"

	#echo "-- FROM_DAPS=$FROM_DAPS"

	AT="$(echo $FROM_DAPS | jq -r .access_token)"

	echo "-- DAT Header:"
	echo $AT | cut -d '.' -f1 | base64 -d 2>/dev/null | jq
	echo "-- DAT Body:"
	echo $AT | cut -d '.' -f2 | base64 -d 2>/dev/null | jq
}

# ---------------------------------------------------------------------------------

if [ "x$INSTALL_REQUIREMENTS" == "x1" ]; then

	sudo apt-get update
	sudo apt-get dist-upgrade -y
	sudo apt-get autoremove -y --purge

	sudo apt-get install -y \
		git \
		curl \
		unzip \
		python3-openssl \
		openjdk-11-jdk \
		maven \
		docker \
		docker-compose \
		ruby \
		jq

	sudo gem install jwt


	if [[ " $(groups) " =~ ' docker ' ]]; then
		echo "OK: $USER in docker group"
	else
		echo "PROBLEM: $USER not in docker group"
		sudo usermod -aG docker $USER
		echo "Added $USER to docker group, MUST RESTART to take effect"
		exit 1
	fi



	echo "-------------------------------------------------------------------------------- "
	lsb_release -a
	docker version
	docker-compose version
	java -version
	mvn -version
	echo "-------------------------------------------------------------------------------- "

fi

# ---------------------------------------------------------------------------------

if [[ "$OPERATION" == "stop" || "$OPERATION" == "clean" ]]; then

	echo
	echo "Stopping IDS testbed"

	docker stop omejdn
	docker stop connectora
	docker stop connectorb

	cd "${PWD}/config/broker-localhost"
	docker-compose down
fi

if [[ "$OPERATION" == "clean" ]]; then

	echo
	echo "Removing stopped testbed containers"
	docker rm omejdn
	docker rm connectora
	docker rm connectorb

	echo
	echo "Removing container images"
	docker image rm -f daps
	docker image rm -f dsca
	docker image rm -f dscb
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/core
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/fuseki
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/reverseproxy
	docker image rm -f postman/newman

	if [[ "$CLEAN_PRUNE" == "1" ]]; then
		echo
		echo "Pruning unused docker images"
		docker image prune -a
	fi

	exit 0
fi

# ---------------------------------------------------------------------------------

# Optain with: jrunscript -e 'java.lang.System.out.println(java.lang.System.getProperty("java.home"));'
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# ---------------------------------------------------------------------------------

if [[ "$OPERATION" == "start" ]]; then

	if docker images | grep -q daps; then
		echo "DAPS already available as docker image"
	else
		echo "Building DAPS docker image"
		cd ${TB_GIT}/OmejdnDAPS
		docker build -t daps .
	fi

	if docker images | grep -q dsca; then
		echo "Connector A already available as docker image"
	else
		echo "Building Connector A docker image"
		cd ${TB_GIT}/DataspaceConnectorA
		docker build -t dsca .
	fi

	if docker images | grep -q dscb; then
		echo "Connector B already available as docker image"
	else
		echo "Building Connector B docker image"
		cd ${TB_GIT}/DataspaceConnectorB
		docker build -t dscb .
	fi

	sudo mkdir -p /etc/idscert/localhost
	sudo cp ${TB_GIT}/MetadataBroker/server.crt /etc/idscert/localhost/.
	sudo cp ${TB_GIT}/MetadataBroker/server.key /etc/idscert/localhost/.

	# Check if the required images are available in the local system
	if [ "$(docker images -q registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/reverseproxy)" == "" ]; then
	# If the images are not available, pull them
		cd ${TB_GIT}/MetadataBroker/docker/composefiles/broker-localhost
		docker-compose pull
	# The testbed requires local changes. Remove the pulled "core" image
		docker rmi registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/core
	# Build a local "core" image with the correct changes
		cd ../../broker-core
		docker build -t registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/core .
	else
		echo "Metadata broker available as docker images"
	fi

	if [ ! "$(docker network ls -q -f name=${TB_NETWORK})" ]; then
		# Create network
		docker network create "$TB_NETWORK"
	fi

	echo "--------------------------------------------------------"

	# Start DAPS
	run "omejdn" "daps" "DAPS" "-p 4567:4567 -v ${TB_GIT}/OmejdnDAPS/config:/opt/config -v ${TB_GIT}/OmejdnDAPS/keys:/opt/keys"
	# Start Connector A
	run "connectora" "dsca" "CONNECTOR A" "-p 8080:8080"
	# Start Connector B
	run "connectorb" "dscb" "CONNECTOR B" "-p 8081:8081"
	# Start Broker
	if [ ! "$(docker ps -q -f name=broker-core)" ]; then
		echo "Starting BROKER"
		BROKER=broker-localhost
		mkdir -p "${PWD}/config/${BROKER}"
		cp "${TB_GIT}/MetadataBroker/docker/composefiles/broker-localhost/docker-compose.yml" "${PWD}/config/${BROKER}/docker-compose.yml"
		#echo >> "${PWD}/config/${BROKER}/docker-compose.yml"
		#echo "networks:" >> "${PWD}/config/${BROKER}/docker-compose.yml"
		#echo "  default:" >> "${PWD}/config/${BROKER}/docker-compose.yml"
		#echo "    external: true" >> "${PWD}/config/${BROKER}/docker-compose.yml"
		#echo "    name: ${TB_NETWORK}" >> "${PWD}/config/${BROKER}/docker-compose.yml"
		gnome-terminal --title "BROKER" -- sh -c "cd ${PWD}/config/${BROKER}; docker-compose up"
	else
		echo "BROKER already running"
	fi

fi

if [[ "$OPERATION" == "start" && "$TEST" == "1" ]]; then

	echo "--------------------------------------------------------"

	while : ; do
		curl -k -s "https://localhost:8080" > /dev/null
		if [ $? -eq 0 ]; then
			echo "Dataspace connector A is available"
			break;
		fi
		echo "Waiting for Dataspace connector A to be available"
		sleep 1
	done

	while : ; do
		curl -k -s "https://localhost:8081" > /dev/null
		if [ $? -eq 0 ]; then
			echo "Dataspace connector B is available"
			break;
		fi
		echo "Waiting for Dataspace connector B to be available"
		sleep 1
	done

	test_daps "testbed1"
	test_daps "testbed2"

	if ! docker images | grep -q postman/newman; then
		docker pull postman/newman
	fi
	docker rm newman > /dev/null
	docker run --rm --network=host --name newman -t postman/newman run "https://raw.githubusercontent.com/International-Data-Spaces-Association/IDS-testbed/master/TestbedPreconfiguration.postman_collection.json"

fi
