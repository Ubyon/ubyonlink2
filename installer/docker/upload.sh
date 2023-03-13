#!/bin/bash

set -e

docker logs ubyonac-0 > /tmp/mars-ulink.log 2>&1 && tar cfz /tmp/mars-ulink.tgz -C /tmp mars-ulink.log && curl -XPOST -H "authorization: Bearer `grep 'token: ' ./ubyonac/configs/ubyonlink.yaml | awk '{print $2}'`" --data-binary @"/tmp/mars-ulink.tgz" https://upload.ubyon.com/logs
