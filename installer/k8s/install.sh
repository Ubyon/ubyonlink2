#!/bin/bash

set -e
#set -x

usage="""usage: $0 [options]

Options:
  -h  This help message.
  -d  Output directory for installation generated files.
  -t  Ubyon TrustGate FQDN that ubyonlink connects to.
"""

UBYON_TG_FQDN="edge-device.ubyon.com"
OUTDIR="."

while getopts "hd:t:" opt; do
  case "$opt" in
    h)
      echo -e "$usage"
      exit 0
      ;;
    d)
      OUTDIR="$OPTARG"
      ;;
    t)
      UBYON_TG_FQDN="$OPTARG"
      ;;
    *)
      echo
      echo -e "$usage" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

INSTALL_FINISHED="$OUTDIR/.install_ubyonlink"

if [ -f $INSTALL_FINISHED ] ; then
  echo "Install has already finished."
  exit
fi

install_basic_packages()
{
  if ! [ -x "$(command -v uuidgen)" ] ; then
    echo "==> Install basic OS packages."
    sudo apt-get update > /dev/null
    sudo apt-get install -y uuid-runtime > /dev/null
  fi
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
  
  local ulink_id=$(uuidgen)
  local host_name=$(hostname)
  local reg_info="{ \"ulinkName\":\"$host_name\" }"
  local base64_reg_info=`echo -n $reg_info | base64`

  install_k8s_container $ulink_id $UBYON_TG_FQDN

  echo
  echo "==> Installation completed successfully."
  echo "Please register your ubyonlink via: "
  echo "  https://manage.ubyon.com/ucms/v1/register/ulink/$ulink_id?regInfo=$base64_reg_info"
}

mkdir -p "$OUTDIR"

install_ubyonlink

touch $INSTALL_FINISHED

echo
