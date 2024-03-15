#!/bin/bash

set -e
#set -x

usage="""usage: $0 [options]

Options:
  -h  This help message.
  -t  Ubyon TrustGate FQDN that AppConnector connects to.
"""

CA_CERT=
JWT_TOKEN=
UBYON_TG_FQDN=
EXTRA_GFLAGS=
TLS_CLIENT_CERT=
TLS_CLIENT_KEY=
SCRIPT_DIR=$(dirname $0)
MARS_ULINK_CONFIG_DIR=$(readlink -f "${SCRIPT_DIR}")/ubyonac/configs
MARS_ULINK_CERTS_DIR=$(readlink -f "${SCRIPT_DIR}")/ubyonac/certs

key_cnt=0
last_key_cnt=0
while getopts "hp:t:k:v:z" opt; do
  case "$opt" in
    h)
      echo -e "$usage"
      exit 0
      ;;
    t)
      UBYON_TG_FQDN="$OPTARG"
      ;;
    z)
      EXTRA_GFLAGS="--tls_ca_cert=default"
      ;;
    k)
      KEYS[${key_cnt}]="$OPTARG"
      VALUES[${key_cnt}]="Default"
      last_key_cnt=${key_cnt}
      key_cnt=$(( ${key_cnt} + 1 ))
      ;;
    v)
      VALUES[${last_key_cnt}]="$OPTARG"
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

set +e
docker ps > /dev/null 2>&1
if [ $? -ne 0 ] ; then
  echo "Script requires docker env."
  echo
  echo "If docker is installed, add '$USER' to 'docker' group via following command:"
  echo "    sudo groupadd docker; sudo usermod -aG docker $USER"
  echo "Relogin then rerun installation. Reboot if still got error."
  echo
  exit
fi
set -e

INSTALL_FINISHED="/etc/systemd/system/ubyonac.service"
if [ -f $INSTALL_FINISHED ] ; then
  echo "Install has already finished."
  exit
fi

# Initialize TG endpoint if it is not specified from user.
if [ "$UBYON_TG_FQDN" == "" ] ; then
  UBYON_TG_FQDN="ulink.ubyon.com"
fi

install_packages()
{
  if ! [ -x "$(command -v uuidgen)" ] ; then
    echo "==> Install basic OS packages."
    sudo apt-get update > /dev/null
    sudo apt-get install -y uuid-runtime > /dev/null
  fi

  # Patch ubyonlink.yaml with the following attributes:
  #  -. Host name
  #  -. Ssh principal
  #  -. JWT token
  #
  mkdir -p $MARS_ULINK_CONFIG_DIR
  local mars_ulink_config_file=$MARS_ULINK_CONFIG_DIR/ubyonlink.yaml
  tee $mars_ulink_config_file > /dev/null <<EOF
# Nmae of the UbyonLink.
# name: <ulink_name>

# Type of deployment: native/docker/k8s
deployment: docker

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
  sed -i "s/# name: .*/name: $host_name/" $mars_ulink_config_file
  sed -i "s/# principal: .*/principal: $user_name/" $mars_ulink_config_file

  if [ "$JWT_TOKEN" != "" ] ; then
    sed -i "s/# token: .*/token: $JWT_TOKEN/" $mars_ulink_config_file
  fi

  if [ $key_cnt -gt 0 ]; then
    indent=""
    echo "${indent}""labels:" | sudo tee -a $mars_ulink_config_file > /dev/null
    cnt=0
    while  [ ${cnt} -lt ${key_cnt} ]; do
      key=${KEYS[${cnt}]}
      val=${VALUES[${cnt}]}
      echo "${indent}""  - key: ${key}" | sudo tee -a $mars_ulink_config_file > /dev/null
      echo "${indent}""    value: ${val}" | sudo tee -a $mars_ulink_config_file > /dev/null
      cnt=$(( ${cnt}+1 ))
    done
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

maybe_install_client_cert()
{
  if [ "$TLS_CLIENT_CERT" == "" ] ; then
    return
  fi

  echo "==> Install gRPC client cert."

  mkdir -p $MARS_ULINK_CERTS_DIR
  tee $MARS_ULINK_CERTS_DIR/tls.key > /dev/null <<EOF
`echo -n $TLS_CLIENT_KEY | base64 -d`
EOF
  chmod 600 $MARS_ULINK_CERTS_DIR/tls.key

  tee $MARS_ULINK_CERTS_DIR/tls.crt > /dev/null <<EOF
`echo -n $TLS_CLIENT_CERT | base64 -d`
EOF
}

install_daemon()
{
  echo "==> Install service ubyonac."

  local mars_cluster_id="$1"
  local mars_ulink_endpoint="$2"
  local user_name=$(id -u -n)
  local group_name=$(id -g -n)

  if [ "$TLS_CLIENT_CERT" != "" ] ; then
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
    --volume $MARS_ULINK_CONFIG_DIR:/home/ubyon/configs:z \\
    --volume $MARS_ULINK_CERTS_DIR:/etc/tls:z \\
    quay.io/ubyon/mars-ulink:1.0.0 /home/ubyon/bin/mars \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    $EXTRA_GFLAGS --v=0
ExecStop=/usr/bin/docker stop ubyonac
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF
  else
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
    --volume $MARS_ULINK_CONFIG_DIR:/home/ubyon/configs:z \\
    quay.io/ubyon/mars-ulink:1.0.0 /home/ubyon/bin/mars \\
    --mars_cluster_id=$mars_cluster_id \\
    --mars_ulink_endpoint=$mars_ulink_endpoint \\
    $EXTRA_GFLAGS --v=0
ExecStop=/usr/bin/docker stop ubyonac
Restart=always
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF
  fi

  # Start ubyonac daemon.
  sudo systemctl daemon-reload
  sudo systemctl start --no-block ubyonac
  sudo systemctl enable ubyonac
}

install_ubyonac()
{
  # Install packages.
  install_packages || return
  
  # Install gRPC client cert if it is given.
  maybe_install_client_cert || return

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
    echo "2. Save the token into ${MARS_ULINK_CONFIG_DIR}/ubyonlink.yaml"
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
