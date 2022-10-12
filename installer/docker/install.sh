#!/bin/bash

set -e
#set -x

usage="""usage: $0 [options]

Options:
  -h  This help message.
  -d  Output directory for installation generated files.
  -t  Ubyon TrustGate FQDN that AppConnector connects to.
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

if [ $(id -u) == 0 ] ; then
  echo
  echo "Cannot run $0 in root. Run in sudo user!"
  echo
  exit -1
fi

INSTALL_FINISHED="$OUTDIR/.install_ubyonac"
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

install_docker_container()
{
  echo "==> Install docker container."

  local mars_cluster_id="$1"
  local mars_ulink_endpoint="$2"
  local user_name=$(id -u -n)
  local group_name=$(id -g -n)

  sudo tee /etc/systemd/system/ubyonac.service > /dev/null <<EOF
[Unit]
Description=UbyonLink
After=docker.service

[Service]
TimeoutStartSec=0
User=$user_name
Group=$group_name
ExecStartPre=/usr/bin/docker pull quay.io/ubyon/mars-ulink:1.0.0
ExecStart=/usr/bin/docker run --rm --network host --name ubyonac \\
    quay.io/ubyon/mars-ulink:1.0.0 /home/ubyon/bin/mars \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    --v=0
ExecStop=/usr/bin/docker stop ubyonac
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

  # Start ubyonac docker container.
  sudo systemctl start --no-block ubyonac
  sudo systemctl enable ubyonac
}

install_ubyonac()
{
  install_basic_packages
  
  local ulink_id=$(uuidgen)
  local host_name=$(hostname)
  local reg_info="{ \"ulinkId\":\"$ulink_id\", \"ulinkName\":\"$host_name\" }"
  local base64_reg_info=`echo -n $reg_info | base64`

  install_docker_container $ulink_id $UBYON_TG_FQDN

  echo
  echo "==> Installation completed successfully."
  echo "Please register your Ubyon AppConnector via: "
  echo "  https://manage.ubyon.com/admin-portal/ulink/register/reg_info=$base64_reg_info"
}

mkdir -p "$OUTDIR"

install_ubyonac

touch $INSTALL_FINISHED

echo
