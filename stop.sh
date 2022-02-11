#!/bin/bash

export PWD="$(dirname $(readlink -f $0))"

docker stop omejdn
docker stop connectora
docker stop connectorb

cd "${PWD}/config/broker-localhost"
docker-compose down
