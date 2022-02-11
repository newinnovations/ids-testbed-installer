#!/bin/bash

# Install script for IDSA IDS-Testbed
#
# Martin van der Werff (martin.vanderwerff (at) tno.nl)
#
# Compatible with commit 382e19308720b386b7268c4e72c0ef0319948027 (Tue Feb 1 11:29:53 2022 +0100)


export TB_GIT="${HOME}/IDS-testbed"
export PWD="$(dirname $(readlink -f $0))"
export TB_COUNTRY=NL
export TB_ORGANIZATION=TNO

#export TB_NETWORK=testbed
export TB_NETWORK=broker-localhost_default

INSTALL_REQUIREMENTS=0
FORCE_REINSTALL=1

# ---------------------------------------------------------------------------------

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

	docker network create "$TB_NETWORK"
fi

# ---------------------------------------------------------------------------------

if [ "x$FORCE_REINSTALL" == "x1" ]; then
	docker image rm -f daps
	docker image rm -f dsca
	docker image rm -f dscb
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/core
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/fuseki
	docker image rm -f registry.gitlab.cc-asp.fraunhofer.de/eis-ids/broker-open/reverseproxy
fi

# Optain with: jrunscript -e 'java.lang.System.out.println(java.lang.System.getProperty("java.home"));'
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# ---------------------------------------------------------------------------------

if docker images | grep -q daps; then
	echo "DAPS available as docker image"
else
	echo "Building DAPS docker image"
	cd ${TB_GIT}/OmejdnDAPS
	docker build -t daps .
fi

if docker images | grep -q dsca; then
	echo "Connector A available as docker image"
else
	echo "Building Connector A docker image"
	cd ${TB_GIT}/DataspaceConnectorA
	docker build -t dsca .
fi

if docker images | grep -q dscb; then
	echo "Connector B available as docker image"
else
	echo "Building Connector B docker image"
	cd ${TB_GIT}/DataspaceConnectorB
	docker build -t dscb .
fi

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


# Start DAPS
run "omejdn" "daps" "DAPS" "-p 4567:4567 -v ${TB_GIT}/OmejdnDAPS/config:/opt/config -v ${TB_GIT}/OmejdnDAPS/keys:/opt/keys"
# Start Connector A
run "connectora" "dsca" "CONNECTOR A" "-p 8080:8080"
# Start Connector B
run "connectorb" "dscb" "CONNECTOR B" "-p 8081:8081"
# Start Broker
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

# ---------------------------------------------------------------------------------

sleep 2

test_daps "testbed1"
test_daps "testbed2"


echo
echo "Testing DAT in Dataspace Connectors"

curl -X 'POST' 'https://localhost:8080/api/ids/connector/update?recipient=https%3A%2F%2Fgoogle.com' -H 'accept: */*' -d '' -u admin:password --insecure -# > /dev/null
docker logs connectora | grep 'DAT' | tail -2
curl -X 'POST' 'https://localhost:8081/api/ids/connector/update?recipient=https%3A%2F%2Fgoogle.com' -H 'accept: */*' -d '' -u admin:password --insecure -# > /dev/null
docker logs connectorb | grep 'DAT' | tail -2
