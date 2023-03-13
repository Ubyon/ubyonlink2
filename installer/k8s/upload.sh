#!/bin/bash

set -e

kubectl logs ubyonac-0 > /tmp/mars-ulink.log && tar cfz /tmp/mars-ulink.tgz -C /tmp mars-ulink.log && curl -XPOST -H "authorization: Bearer `grep 'token: ' ./ubyonac/configs/ubyonlink.yaml | awk '{print $2}'`" --data-binary @"/tmp/mars-ulink.tgz" https://upload.ubyon.com/logs
