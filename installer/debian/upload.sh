#!/bin/bash

set -e

tar cfz /tmp/mars-ulink.tgz -C /home/ubyon/logs . && curl -XPOST -H "authorization: Bearer `grep 'token: ' /home/ubyon/configs/ubyonlink.yaml |awk '{print $2}'`" --data-binary @"/tmp/mars-ulink.tgz" https://upload.ubyon.com/logs
