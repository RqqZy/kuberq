#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

BASE=/opt/kuberq
DOCKER_VER=24.0.5
K8S_BIN_VER=v1.28.11
calicoVer=v3.24.6
# https://github.com/coredns/coredns
corednsVer=1.11.1
dnsNodeCacheVer=1.22.23
metricsVer=v0.6.4
pauseVer=3.9
REGISTRY_MIRROR=CN
ARCH=$(uname -m)
#cd /opt/ && git clone https://github.com/RqqZy/kuberq

function logger() {
  TIMESTAMP=$(date +'%Y-%m-%d %H:%M:%S')
  case "$1" in
    debug)
      echo -e "$TIMESTAMP \033[36mDEBUG\033[0m $2"
      ;;
    info)
      echo -e "$TIMESTAMP \033[32mINFO\033[0m $2"
      ;;
    warn)
      echo -e "$TIMESTAMP \033[33mWARN\033[0m $2"
      ;;
    error)
      echo -e "$TIMESTAMP \033[31mERROR\033[0m $2"
      ;;
    *)
      ;;
  esac
}

function download_docker() {
    mkdir -p $BASE/{down,bin}
  if [[ "$REGISTRY_MIRROR" == CN ]];then
    DOCKER_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable/${ARCH}/docker-${DOCKER_VER}.tgz"
  else
    DOCKER_URL="https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VER}.tgz"
  fi

  if [[ -f "$BASE/down/docker-${DOCKER_VER}.tgz" ]];then
    logger warn "docker binaries already existed"
  else
    logger info "downloading docker binaries, arch:$ARCH, version:$DOCKER_VER"
    if [[ -e /usr/bin/wget ]];then
      wget -c --no-check-certificate "$DOCKER_URL" || { logger error "downloading docker failed"; exit 1; }
    else
      curl -k -C- -O --retry 3 "$DOCKER_URL" || { logger error "downloading docker failed"; exit 1; }
    fi
    mv -f "./docker-$DOCKER_VER.tgz" "$BASE/down"
  fi

  tar zxf "$BASE/down/docker-$DOCKER_VER.tgz" -C "$BASE/down" && \
  cp -f "$BASE"/down/docker/* "$BASE/bin" && \
  mv -f "$BASE"/down/docker/* $BASE/bin && \
  ln -sf $BASE/bin/docker /bin/docker
}

function install_docker() {
  # check if a container runtime is already installed
  systemctl status docker|grep Active|grep -q running && { logger warn "docker is already running."; return 0; }

  logger debug "generate docker service file"
  cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=http://docs.docker.io
[Service]
Environment="PATH=/opt/kuberq/bin:/bin:/sbin:/usr/bin:/usr/sbin"
ExecStart=/opt/kuberq/bin/dockerd
ExecStartPost=/sbin/iptables -I FORWARD -s 0.0.0.0/0 -j ACCEPT
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
[Install]
WantedBy=multi-user.target
EOF

  # configuration for dockerd
  mkdir -p /etc/docker
  DOCKER_VER_MAIN=$(echo "$DOCKER_VER"|cut -d. -f1)
  CGROUP_DRIVER="cgroupfs"
  ((DOCKER_VER_MAIN>=20)) && CGROUP_DRIVER="systemd"
  logger debug "generate docker config: /etc/docker/daemon.json"
  if [[ "$REGISTRY_MIRROR" == CN ]];then
    logger debug "prepare register mirror for $REGISTRY_MIRROR"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "registry-mirrors":[
    "https://x9r52uz5.mirror.aliyuncs.com",
    "https://dockerhub.icu",
    "https://docker.chenby.cn",
    "https://docker.1panel.live",
    "https://docker.awsl9527.cn",
    "https://docker.anyhub.us.kg",
    "https://dhub.kubesre.xyz"
  ],
  "insecure-registries": ["http://kuberq.io.local:5000"],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  else
    logger debug "standard config without registry mirrors"
    cat > /etc/docker/daemon.json << EOF
{
  "exec-opts": ["native.cgroupdriver=$CGROUP_DRIVER"],
  "insecure-registries": ["http://kuberq.io.local:5000"],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-level": "warn",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
    },
  "data-root": "/var/lib/docker"
}
EOF
  fi

  # docker proxy setting
  http_proxy=${http_proxy:-}
  HTTP_PROXY=${HTTP_PROXY:-$http_proxy}
  https_proxy=${https_proxy:-}
  HTTPS_PROXY=${HTTPS_PROXY:-$https_proxy}
  USE_PROXY=0
  CONFIG="[Service]\n"

  if [[ -n ${HTTP_PROXY} ]]; then
    USE_PROXY=1
    CONFIG=${CONFIG}"Environment=HTTP_PROXY=${HTTP_PROXY}\n"
  fi
  if [[ -n ${HTTPS_PROXY} ]]; then
    USE_PROXY=1
    CONFIG=${CONFIG}"Environment=HTTPS_PROXY=${HTTPS_PROXY}\n"
  fi
  if [[ ${USE_PROXY} == 1 ]]; then
    logger debug "generate docker service http proxy file"
    mkdir -p /etc/systemd/system/docker.service.d
    c=$(echo -e "$CONFIG")
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf << EOF
${c}
EOF
  fi

  if [[ -f /etc/selinux/config ]]; then
    logger debug "turn off selinux"
    getenforce|grep Disabled || setenforce 0
    sed -i 's/^SELINUX=.*$/SELINUX=disabled/g' /etc/selinux/config
  fi

  logger debug "enable and start docker"
  systemctl enable docker
  systemctl daemon-reload && systemctl restart docker && sleep 4
}
function get_k8s_bin() {
  [[ -f "$BASE/bin/kubelet" ]] && { logger warn "kubernetes binaries existed"; return 0; }
  
  logger info "downloading kubernetes: $K8S_BIN_VER binaries"
  rm -rf "$BASE/k8s_bin_tmp"
  docker ps -a |grep -q temp_k8s_bin && { logger debug "remove existing container"; docker rm -f temp_k8s_bin; }
  docker pull registry.cn-shanghai.aliyuncs.com/rqq0820/serice:"$K8S_BIN_VER" && \
  logger debug "run a temporary container" && \
  docker run -d --name temp_k8s_bin registry.cn-shanghai.aliyuncs.com/rqq0820/serice:${K8S_BIN_VER} && \
  logger debug "cp k8s binaries" && \
  docker cp temp_k8s_bin:/k8s "$BASE/k8s_bin_tmp" && \
  /bin/mv -f "$BASE"/k8s_bin_tmp/* "$BASE/bin" && \
  logger debug "stop&remove temporary container" && \
  docker rm -f temp_k8s_bin && \
  rm -rf "$BASE/k8s_bin_tmp"
}
function start_kuberq_docker() {

  # get host's IP
  host_if=$(ip route|grep default|head -n1|cut -d' ' -f5)
  host_ip=$(ip a|grep "$host_if$"|head -n1|awk '{print $2}'|cut -d'/' -f1)
  logger debug "get host IP: $host_ip"

  # allow ssh login using key locally
  if [[ ! -e /root/.ssh/id_rsa ]]; then
    logger debug "generate ssh key pair"
    ssh-keygen -t rsa -b 2048 -N '' -f /root/.ssh/id_rsa > /dev/null
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
    ssh-keyscan -t ecdsa -H "$host_ip" >> /root/.ssh/known_hosts
  fi

  # run kubeasz docker container
#      --volume "$BASE":"$BASE" \
  docker run --detach \
      --env HOST_IP="$host_ip" \
      --name kuberq \
      --network host \
      --restart always \
      --volume /root/.kube:/root/.kube \
      --volume /root/.ssh:/root/.ssh \
      --volume /etc/docker:/etc/docker \
      --volume $BASE:$BASE \
      --volume /etc/calico:/etc/calico \
      --volume /etc/kubernetes:/etc/kubernetes \
      registry.cn-shanghai.aliyuncs.com/rqq0820/serice:ansible 
}
download_docker
install_docker
get_k8s_bin
start_kuberq_docker
