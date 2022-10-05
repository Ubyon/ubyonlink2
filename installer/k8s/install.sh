#!/bin/bash

set -e

#set -x

# Output directory for the k8s yaml files.
OUTDIR="${1:-.}"

# Management FQDN.
CORE_MGMT_FQDN="${1:-manage.ubyon.com}"

# TrustGate FQDN that ubyonlink connects to.
ULINK_SERVER_FQDN="${2:-edge-device.ubyon.com}"

INSTALL_FINISHED="$OUTDIR/.install_ubyonlink"

if [ -f $INSTALL_FINISHED ] ; then
  echo "Install has already finished."
  exit
fi

install_basic_packages()
{
  echo "==> Install basic OS packages."
  sudo apt-get update > /dev/null
  sudo apt-get install -y uuid-runtime > /dev/null
}

install_k8s_container()
{
  echo "==> Install k8s container."

  local mars_cluster_id="$1"
  local mars_ulink_endpoint="$2"

  cat > $OUTDIR/ubyonlink.yaml <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ubyonlink
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ubyonlink
  serviceName: ubyonlink
  template:
    metadata:
      labels:
        app: ubyonlink
        version: 1.0.0
    spec:
      hostNetwork: true
      containers:
      - name: ubyonlink
        imagePullPolicy: Always
        image: quay.io/ubyon/mars-ulink:1.0.0
        command: ["/home/ubyon/bin/mars"]
        args: ["--mars_cluster_id=$mars_cluster_id",
               "--mars_ulink_endpoint=$mars_ulink_endpoint",
               "--v=0"]
        env:
          - name: MY_POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: MY_POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
          - name: MY_POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
EOF

  kubectl apply -f $OUTDIR/ubyonlink.yaml
}

install_ubyonlink()
{
  install_basic_packages
  
  local cluster_id=$(uuidgen)
  install_k8s_container $cluster_id $ULINK_SERVER_FQDN

  echo
  echo "==> Installation completed successfully."
  echo "Please register your ubyonlink via: "
  echo "  https://$CORE_MGMT_FQDN/ucms/register/$cluster_id"
}

mkdir -p "$OUTDIR"

install_ubyonlink

touch $INSTALL_FINISHED

echo
