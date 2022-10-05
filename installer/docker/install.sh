#!/bin/bash

set -e
#set -x

if [ $(id -u) == 0 ] ; then
  echo
  echo "Cannot run $0 in root. Run in sudo user!"
  echo
  exit -1
fi

# Output directory to mark the installation complete.
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

install_docker_container()
{
  echo "==> Install docker container."

  local mars_cluster_id="$1"
  local mars_ulink_endpoint="$2"
  local user_name=$(id -u -n)
  local group_name=$(id -g -n)

  sudo tee /etc/systemd/system/ubyonlink.service > /dev/null <<EOF
[Unit]
Description=UbyonLink
After=docker.service

[Service]
TimeoutStartSec=0
User=$user_name
Group=$group_name
ExecStartPre=/usr/bin/docker pull quay.io/ubyon/mars-ulink:1.0.0
ExecStart=/usr/bin/docker run --rm --network host --name ubyonlink \\
    quay.io/ubyon/mars-ulink:1.0.0 /home/ubyon/bin/mars \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    --v=0
ExecStop=/usr/bin/docker stop ubyonlink
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

  # Start ubyonlink docker container.
  sudo systemctl start --no-block ubyonlink
  sudo systemctl enable ubyonlink
}

install_ubyonlink()
{
  install_basic_packages
  
  local ulink_id=$(uuidgen)
  install_docker_container $ulink_id $ULINK_SERVER_FQDN

  echo
  echo "==> Installation completed successfully."
  echo "Please register your ubyonlink via: "
  echo "  https://$CORE_MGMT_FQDN/ucms/v1/register/ulink/$ulink_id"
}

mkdir -p "$OUTDIR"

install_ubyonlink

touch $INSTALL_FINISHED

echo
