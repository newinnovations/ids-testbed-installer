#!/bin/bash

export TB_GIT=${HOME}/IDS-testbed

docker stop omejdn
docker stop connectora
docker stop connectorb

cd ${TB_GIT}/MetadataBroker/docker/composefiles/broker-localhost
docker-compose down
