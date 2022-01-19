#!/bin/bash

# Install script for IDSA IDS-Testbed
#
# Martin van der Werff (martin.vanderwerff (at) tno.nl)
#
# Compatible with commit 6c216c31488d2afcad6984202dbf9aecb5373714 (Thu Dec 2 15:25:04 2021 +0100)

export TB_GIT=${HOME}/IDS-testbed
export TB_DIR=${HOME}/MyTestbed
export TB_COUNTRY=NL
export TB_ORGANIZATION=TNO

INSTALL_REQUIREMENTS=1
FORCE_REINSTALL=0

# ---------------------------------------------------------------------------------

function client_id() {
	local CERT="$(openssl x509 -in "${TB_DIR}/CertificationAuthority/data/cert/$1.cert" -text)"
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
filename = "$TB_DIR/CertificationAuthority/data/cert/$CLIENT_NAME.key"
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

	docker network create testbed
fi

# ---------------------------------------------------------------------------------

mkdir -p ${TB_DIR}

if [ "x$FORCE_REINSTALL" == "x1" ]; then
	# Remove directories to force re-install
	rm -fr ${TB_DIR}/CertificationAuthority
	rm -fr ${TB_DIR}/OmejdnDAPS
	rm -fr ${TB_DIR}/DataspaceConnector
fi

# Optain with: jrunscript -e 'java.lang.System.out.println(java.lang.System.getProperty("java.home"));'
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

# ---------------------------------------------------------------------------------


if [ ! -d ${TB_DIR}/CertificationAuthority ]; then

	cd ${TB_DIR}
	unzip ${TB_GIT}/Testbed/CertificationAuthority/CertificationAuthority.zip
	cd CertificationAuthority
	chmod a+x *.py

	./pki.py init
	./pki.py ca create --common-name "Testbed CA" --algo "rsa" --bits "2048" --country-name "${TB_COUNTRY}" --organization-name "${TB_ORGANIZATION}"
	./pki.py subca create --CA "Testbed CA" --common-name "Testbed SubCA" --algo "rsa" --bits "2048" --country-name "${TB_COUNTRY}" --organization-name "${TB_ORGANIZATION}"
	./pki.py cert create --subCA "Testbed SubCA" --common-name "TestbedCert" --algo "rsa" --bits "2048" --country-name "${TB_COUNTRY}" --organization-name "${TB_ORGANIZATION}" --client --server
	./pki.py cert create --subCA "Testbed SubCA" --common-name "TestbedCert2" --algo "rsa" --bits "2048" --country-name "${TB_COUNTRY}" --organization-name "${TB_ORGANIZATION}" --client --server
	cd data/cert
	openssl pkcs12 -export -out TestbedCert.p12 -inkey TestbedCert.key -in TestbedCert.crt -passout pass:password
	openssl pkcs12 -in TestbedCert.p12 -out TestbedCert.cert -nokeys -nodes -passin pass:password
	openssl pkcs12 -export -out TestbedCert2.p12 -inkey TestbedCert2.key -in TestbedCert2.crt -passout pass:password
	openssl pkcs12 -in TestbedCert2.p12 -out TestbedCert2.cert -nokeys -nodes -passin pass:password
	ls -l ${TB_DIR}/CertificationAuthority/data/*/*
fi

# ---------------------------------------------------------------------------------

if [ ! -d ${TB_DIR}/OmejdnDAPS ]; then

	cd ${TB_DIR}
	unzip ${TB_GIT}/Testbed/OmejdnDAPS/OmejdnDAPS.zip
	cd OmejdnDAPS

	cp ${TB_DIR}/CertificationAuthority/data/cert/*.cert ./keys/.

	ID=$(client_id "TestbedCert")
	sed -i "2s,testClient,${ID}," config/clients.yml
	sed -i "8s,testClient,TestbedCert.cert," config/clients.yml

	ID=$(client_id "TestbedCert2")
	sed -i "9s,testClient2,${ID}," config/clients.yml
	sed -i "15s,testClient2,TestbedCert2.cert," config/clients.yml

	sed -i '2s,http://localhost:4567,idsc:IDS_CONNECTORS_ALL,' config/omejdn.yml
	sed -i '8s,TestServer,idsc:IDS_CONNECTORS_ALL,' config/omejdn.yml

	docker build -t daps .

	if [ "$(docker ps -q -f name=omejdn)" ]; then
		docker stop omejdn
	fi

	if [ "$(docker ps -aq -f status=exited -f name=omejdn)" ]; then
		docker rm omejdn
	fi

	docker run -d --name omejdn -p 4567:4567 -v $PWD/config:/opt/config -v $PWD/keys:/opt/keys --network=testbed daps
else
	docker start omejdn
fi

# ---------------------------------------------------------------------------------

if [ ! -d ${TB_DIR}/DataspaceConnector ]; then

	cd ${TB_DIR}
	unzip ${TB_GIT}/Testbed/DataspaceConnector/DataspaceConnector.zip
	cd DataspaceConnector

	#mvn clean package

	cp ${TB_DIR}/CertificationAuthority/data/cert/TestbedCert.p12 ./src/main/resources/conf/.

	sed -i '59s,localhost,omejdn,' ./src/main/resources/application.properties
	sed -i '60s,localhost,omejdn,' ./src/main/resources/application.properties
	sed -i '12s,TEST_DEPLOYMENT,PRODUCTIVE_DEPLOYMENT,' ./src/main/resources/conf/config.json
	sed -i '60s,keystore-localhost.p12,TestbedCert.p12,' ./src/main/resources/conf/config.json

	docker build -t dsc .

	if [ "$(docker ps -q -f name=dsccontainer)" ]; then
		docker stop dsccontainer
	fi

	if [ "$(docker ps -aq -f status=exited -f name=dsccontainer)" ]; then
		docker rm dsccontainer
	fi

	docker run -d --name dsccontainer -p 8080:8080 --network=testbed dsc

else
	docker start dsccontainer
fi

while : ; do
	curl -k -s "https://localhost:8080" > /dev/null
	if [ $? -eq 0 ]; then
		echo "Dataspace connector is available"
		break;
	fi
	echo "Waiting for Dataspace connector to be available"
	sleep 1
done

# ---------------------------------------------------------------------------------

sleep 2

test_daps "TestbedCert"
test_daps "TestbedCert2"


echo
echo "Testing DAT in Dataspace Connector"

curl -X 'POST' 'https://localhost:8080/api/ids/connector/update?recipient=https%3A%2F%2Ftno.nl' -H 'accept: */*' -d '' -u admin:password --insecure -# > /dev/null
docker logs dsccontainer | grep 'Dynamic Attribute Token' | tail -2
