#!/bin/bash

set -e
#set -x

usage="""usage: $0 [options]

Options:
  -h  This help message.
  -p  UbyonAC package file.
  -t  Ubyon TrustGate FQDN that AppConnector connects to.
  -z  Use system default root CA certificate.
"""

AC_PACKAGE=
CA_CERT=
JWT_TOKEN=
UBYON_TG_FQDN=
EXTRA_GFLAGS=
MARS_ULINK_CONFIG_DIR=/home/ubyon/configs

while getopts "hp:t:z" opt; do
  case "$opt" in
    h)
      echo -e "$usage"
      exit 0
      ;;
    p)
      AC_PACKAGE="$OPTARG"
      ;;
    t)
      UBYON_TG_FQDN="$OPTARG"
      ;;
    z)
      EXTRA_GFLAGS="--tls_ca_cert=default"
      ;;
    *)
      echo
      echo -e "$usage" 1>&2
      exit 1
      ;;
  esac
done

shift $((OPTIND - 1))

if [ $# != 0 ]; then
  echo
  echo -e "$usage" 1>&2
  echo
  exit -1
fi

if [ $(id -u) = 0 ] ; then
  echo
  echo "Cannot run $0 in root. Run in sudo user!"
  echo
  exit -1
fi

if [[ "`lsb_release -cs`" != "bionic" && "`lsb_release -cs`" != "focal" && "`lsb_release -cs`" != "jammy" ]] ; then
  echo
  echo "  This installation script is for Ubuntu 18.04, 20.04 and 22.04."
  echo
  exit -1
fi

INSTALL_FINISHED="/etc/systemd/system/ubyonac.service"
if [ -f $INSTALL_FINISHED ] ; then
  echo "Install has already finished."
  exit
fi

# Initialize TG endpoint if it is not specified from user.
if [ "$UBYON_TG_FQDN" == "" ] ; then
  UBYON_TG_FQDN="ulink.ubyon.com"
fi

setup_repo()
{
  echo "==> Setup Ubyon debian repository."

  # Add the ubyon debian repo.
  sudo sed -i "1s/^/deb http:\/\/ubyon.github.io\/debian\/ appconnector main\n/" /etc/apt/sources.list

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
  if [ "$AC_PACKAGE" == "" ] ; then
    sudo grep "ubyon.github.io" /etc/apt/sources.list > /dev/null 2>&1 || setup_repo || return
    AC_PACKAGE=ubyon-ac
  fi

  # Update package database.
  echo "==> Run apt-get update."
  sudo apt-get update > /dev/null

  echo "==> Install Ubyon packages."
  sudo apt-get install -y binutils uuid-runtime $AC_PACKAGE || return

  # Patch ubyonlink.yaml with the following attributes:
  #  -. Host name
  #  -. Ssh principal
  #  -. JWT token
  #
  local mars_ulink_config_file=$MARS_ULINK_CONFIG_DIR/ubyonlink.yaml
  sudo tee $mars_ulink_config_file > /dev/null <<EOF
# Nmae of the UbyonLink.
# name: <ulink_name>

# Type of deployment: native/docker/k8s
deployment: native

# Ssh principal.
# principal: <principal>

# Short-lived JWT token that can be used to registered with Ubyon Cloud.
#
# token: <jwt_token>

# System and user defined labels in list of key/value format.
#labels:
#  - key: < key name>
#    value: <key value>
#  - key: <key name>
#    command:
#    - <command>
#    - <arg1>
#    - <arg2>
EOF

  local user_name=$(id -un)
  local host_name=$(hostname)
  sudo sed -i "s/# name: .*/name: $host_name/" $mars_ulink_config_file
  sudo sed -i "s/# principal: .*/principal: $user_name/" $mars_ulink_config_file

  if [ "$JWT_TOKEN" != "" ] ; then
    sudo sed -i "s/# token: .*/token: $JWT_TOKEN/" $mars_ulink_config_file
  fi
}

maybe_enable_cert_based_ssh()
{
  if [ "$CA_CERT" == "" ] ; then
    return
  fi

  echo "==> Enable cert based SSH."
  sudo tee /etc/ssh/ubyon_ca_cert.pub > /dev/null <<EOF
`echo -n $CA_CERT | base64 -d`
EOF

  sudo grep "TrustedUserCAKeys " /etc/ssh/sshd_config > /dev/null 2>&1 || \
    sudo tee -a /etc/ssh/sshd_config > /dev/null <<EOF
TrustedUserCAKeys /etc/ssh/ubyon_ca_cert.pub
EOF

  # ED25519 key should be one of the supported key.
  local accept_keys=$(sudo grep "PubkeyAcceptedKeyTypes" /etc/ssh/sshd_config || true)
  if [ "$accept_keys" != "" ] ; then
    echo $accept_keys | grep "ssh-ed25519-cert-v01@openssh.com" > /dev/null 2>&1 || \
      sudo sed -i "s/^PubkeyAcceptedKeyTypes .*/&,ssh-ed25519-cert-v01@openssh.com/" /etc/ssh/sshd_config
  fi

  sudo systemctl restart sshd
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
ExecStart=/bin/bash -c 'source /etc/profile.d/ubyon_env.sh && /home/ubyon/bin/mars-ulink \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    $EXTRA_GFLAGS --v=0'
TimeoutSec=30
Restart=on-failure
RestartSec=20

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
  install_daemon $ulink_id $UBYON_TG_FQDN || return

  maybe_enable_cert_based_ssh || return

  echo
  echo "==> Installation completed successfully."

  if [ "$JWT_TOKEN" == "" ] ; then
    echo
    echo "==> JWT token is required to register the ubyonac."
    echo "1. Please acquire a registration token via:"
    echo "     https://manage.ubyon.com/<token_path>"
    echo
    echo "2. Save the token into /home/ubyon/configs/ubyonlink.yaml"
    echo "3. Restart ubyonac daemon using following command: "
    echo "     sudo systemctl restart ubyonac"
    echo
  else
    echo
    echo "==> Enjoy..."
    echo
  fi
}

install_ubyonac

echo
