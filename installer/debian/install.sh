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

if [ $(id -u) = 0 ] ; then
  echo
  echo "Cannot run $0 in root. Run in sudo user!"
  echo
  exit -1
fi

if [[ "`lsb_release -cs`" != "focal" && "`lsb_release -cs`" != "jammy" ]] ; then
  echo
  echo "  This installation script is for Ubuntu 20.04 and 22.04."
  echo
  exit -1
fi

INSTALL_FINISHED="$OUTDIR/.install_ubyonac"
if [ -f $INSTALL_FINISHED ] ; then
  echo "Install has already finished."
  exit
fi

setup_repo()
{
  echo "==> Setup Ubyon debian repository."

  # Add the ubyon debian repo.
  sudo sed -i "1s/^/deb http:\/\/ubyon.github.io\/debian\/ appconnector main\n/" /etc/apt/sources.list
  sudo sed -i "1s/^/deb http:\/\/ubyon.github.io\/debian\/ thirdparty main\n/" /etc/apt/sources.list

  # Set ubyon repository to have precedence over other repositories.
  sudo tee -a /etc/apt/preferences > /dev/null <<EOF
Package: *
Pin: origin ubyon.github.io
Pin-Priority: 1001
EOF

  # Import its key.
  curl https://ubyon.github.io/debian/ubyon.gpg.key | sudo tee /etc/apt/trusted.gpg.d/myrepo.asc > /dev/null
}

install_packages()
{
  sudo grep "ubyon.github.io" /etc/apt/sources.list > /dev/null 2>&1 || setup_repo || return

  # Update package database.
  echo "==> Run apt-get update."
  sudo apt-get update > /dev/null

  echo "==> Install Ubyon packages."
  sudo apt-get install -y uuid-runtime ubyon-ac || return
}

install_daemon()
{
  echo "==> Install service ubyonac."

  local mars_cluster_id="$1"
  local mars_ulink_endpoint="$2"

  sudo tee /etc/systemd/system/ubyonac.service > /dev/null <<EOF
[Unit]
Description=UbyonAC
Requires=network.target
After=network.target

[Service]
WorkingDirectory=/home/ubyon/bin
User=ubyon
Group=ubyon
ExecStart=bash -c 'source /etc/profile.d/ubyon_env.sh && /home/ubyon/bin/mars-ulink \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    --v=0'
TimeoutSec=30
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  # Start ubyonac daemon.
  sudo systemctl daemon-reload
  sudo systemctl start --no-block ubyonac
  sudo systemctl enable ubyonac
}

install_ubyonac()
{
  # Install packages.
  install_packages || return
  
  # Install daemon service files and start the daemon.
  local ulink_id=$(uuidgen)
  local host_name=$(hostname)
  local reg_info="{\"ulinkId\":\"$ulink_id\",\"ulinkName\":\"$host_name\"}"
  local base64_reg_info=`echo -n $reg_info | base64 -w0`

  install_daemon $ulink_id $UBYON_TG_FQDN || return

  echo
  echo "==> Installation completed successfully."
  echo "Please register your Ubyon AppConnector via: "
  echo "  https://manage.ubyon.com/admin-portal/ulink/register?reg_info=$base64_reg_info"
}

mkdir -p "$OUTDIR"

install_ubyonac

touch $INSTALL_FINISHED

echo
