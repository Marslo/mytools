#!/bin/bash
# shellcheck disable=SC2224,SC1117,SC2009
# =============================================================================
#   FileName: belloHAKubeCluster.sh
#     Author: marslo.jiao@gmail.com
#    Created: 2019-09-02 22:48:57
# LastChange: 2019-09-17 15:24:16
# =============================================================================

# Inspired by:
  # https://blog.csdn.net/chenleiking/article/details/80136449
  # https://k8smeetup.github.io/docs/setup/independent/high-availability/

# hardcode
master1Ip='127.0.0.40'
master2Ip='127.0.0.42'
master3Ip='127.0.0.43'
master1Name='mytest-tst1'
master2Name='mytest-tst2'
master3Name='mytest-tst3'
virtualIpAddr='127.0.0.50'
leadIP="${master1Ip}"
leadHost="${master1Name}"

k8sVer='v1.15.3'
rtUrl='artifactory.my.com/artifactory'
# etcdPath='/etc/kubernetes/pki'
etcdPath='/etc/etcd/ssl'

# cfsslofficialUrl='https://pkg.cfssl.org/R1.2'
cfsslRtUrl="https://${rtUrl}/devops-local/k8s/R1.2/"
cfsslDownloadUrl="${cfsslRtUrl}"

etcdVer='v3.3.15'
# etcdGoogleDownload='https://storage.googleapis.com/etcd'
# etcdGithubDownload='https://github.com/etcd-io/etcd/releases/download'
etcdRtDownload="https://${rtUrl}/devops-local/k8s"
etcdDownloadUrl="${etcdRtDownload}"
etcdInitialCluster="${master1Name}=https://${master1Ip}:2380,${master2Name}=https://${master2Ip}:2380,${master3Name}=https://${master3Ip}:2380"

keepaliveVer='2.0.18'
# keepaliveUrl='https://www.keepalived.org/software'
keepaliveRtUrl="https://${rtUrl}/devops-local/k8s/software"
keepaliveDownloadUrl="${keepaliveRtUrl}"

# interface=$(ip route get 13.250.177.223 | sed -rn 's|.*dev\s+(\S+)\s+src.*$|\1|p') # get the route to github
interface=$(netstat -nr | grep -E 'UG|UGSc' | grep -E '^0.0.0|default' | grep -E '[0-9.]{7,15}' | awk -F' ' '{print $NF}')
ipAddr=$(ip a s ${interface} | sed -rn 's|.*inet ([0-9\.]{7,15})/[0-9]{2} brd.*$|\1|p')
peerName=$(hostname)

function reportError(){
  set +H
  echo -e "\\033[31mERROR: $1 !!\\033[0m"
  set -H
}

function timeSync() {
  sudo date --set="$(ssh ${leadIP} 'date ')"
}

function cfsslInstallation() {
  sudo bash -c "curl -o /usr/local/bin/cfssl ${cfsslDownloadUrl}/cfssl_linux-amd64"
  sudo bash -c "curl -o /usr/local/bin/cfssljson ${cfsslDownloadUrl}/cfssljson_linux-amd64"
  sudo chmod +x /usr/local/bin/cfssl*
}

function etcdInstallation() {
  curl -sSL ${etcdDownloadUrl}/${etcdVer}/etcd-${etcdVer}-linux-amd64.tar.gz \
      | sudo tar -xzv --strip-components=1 -C /usr/local/bin/
}

function certCA() {
  sudo bash -c "cat > ${etcdPath}/ca-config.json" << EOF
{
  "signing": {
    "default": {
      "expiry": "43800h"
    },
    "profiles": {
      "server": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ]
      },
      "client": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "client auth"
        ]
      },
      "peer": {
        "expiry": "43800h",
        "usages": [
          "signing",
          "key encipherment",
          "server auth",
          "client auth"
        ]
      }
    }
  }
}
EOF

  sudo bash -c "cat > ${etcdPath}/ca-csr.json" << EOF
{
  "CN": "etcd",
  "key": {
    "algo": "rsa",
    "size": 2048
  }
}
EOF

  pushd .
  cd ${etcdPath}
  sudo /usr/local/bin/cfssl gencert \
       -initca ca-csr.json \
       | sudo /usr/local/bin/cfssljson -bare ca -
  popd
}

function certClient() {
  sudo bash -c "cat > ${etcdPath}/client.json" << EOF
{
  "CN": "client",
  "key": {
    "algo": "ecdsa",
    "size": 256
  }
}
EOF

  pushd .
  cd ${etcdPath}/
  sudo /usr/local/bin/cfssl gencert \
       -ca=ca.pem \
       -ca-key=ca-key.pem \
       -config=ca-config.json \
       -profile=client client.json \
       | sudo /usr/local/bin/cfssljson -bare client
  popd
}

function certServerNPeer() {
  sudo bash -c "/usr/local/bin/cfssl print-defaults csr > ${etcdPath}/config.json"
  sudo sed -i '0,/CN/{s/example\.net/'"${peerName}"'/}' ${etcdPath}/config.json
  sudo sed -i 's/www\.example\.net/'"${ipAddr}"'/' ${etcdPath}/config.json
  sudo sed -i 's/example\.net/'"${peerName}"'/' ${etcdPath}/config.json

  pushd .
  cd ${etcdPath}/
  sudo /usr/local/bin/cfssl gencert \
       -ca=ca.pem \
       -ca-key=ca-key.pem \
       -config=ca-config.json \
       -profile=server config.json \
       | sudo /usr/local/bin/cfssljson -bare server
  sudo /usr/local/bin/cfssl gencert \
       -ca=ca.pem \
       -ca-key=ca-key.pem \
       -config=ca-config.json \
       -profile=peer config.json \
       | sudo /usr/local/bin/cfssljson -bare peer
  popd
}

function syncCert() {
  for pkg in ca-config.json  ca-key.pem  ca.pem  client-key.pem  client.pem; do
    sudo rsync -avzrlpgoDP \
               --rsync-path='sudo rsync' \
               root@${leadHost}:${etcdPath}/${pkg} \
               ${etcdPath}/
  done
}

function etcdService() {
  touch /etc/etcd.env
  echo "peerName=${peerName}" >> /etc/etcd.env
  echo "ipAddr=${ipAddr}" >> /etc/etcd.env

  sudo bash -c 'cat > /etc/systemd/system/etcd.service' <<EOF
[Unit]
Description=etcd
Documentation=https://ewiki.marvell.com/x/sTJIBg
Conflicts=etcd.service
Conflicts=etcd2.service

[Service]
EnvironmentFile=/etc/etcd.env
Type=notify
Restart=always
RestartSec=5s
LimitNOFILE=40000
TimeoutStartSec=0

ExecStart=/usr/local/bin/etcd --name ${peerName} \\
    --data-dir /var/lib/etcd \\
    --listen-client-urls https://${ipAddr}:2379 \\
    --advertise-client-urls https://${ipAddr}:2379 \\
    --listen-peer-urls https://${ipAddr}:2380 \\
    --initial-advertise-peer-urls https://${ipAddr}:2380 \\
    --cert-file=${etcdPath}/server.pem \\
    --key-file=${etcdPath}/server-key.pem \\
    --client-cert-auth \\
    --trusted-ca-file=${etcdPath}/ca.pem \\
    --peer-cert-file=${etcdPath}/peer.pem \\
    --peer-key-file=${etcdPath}/peer-key.pem \\
    --peer-client-cert-auth \\
    --peer-trusted-ca-file=${etcdPath}/ca.pem \\
    --initial-cluster ${etcdInitialCluster} \\
    --initial-cluster-token my-etcd-token \\
    --initial-cluster-state new

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl start etcd.service
}

keepaliveSetup() {
  mkdir -p ~/temp
  sudo mkdir -p /etc/keepalived/

  curl -fsSL ${keepaliveDownloadUrl}/keepalived-${keepaliveVer}.tar.gz \
       | tar xzf - -C ~/temp
  pushd .
  cd ~/temp/keepalived-${keepaliveVer}
  ./configure && make
  sudo make install
  sudo cp keepalived/keepalived.service /etc/systemd/system/
  popd

  sudo bash -c 'cat > /etc/keepalived/keepalived.conf' <<EOF
! Configuration File for keepalived
global_defs {
  router_id LVS_DEVEL
}
vrrp_script check_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3
  weight -2
  fall 10
  rise 2
}
vrrp_instance VI_1 {
  state MASTER
  interface ${interface}
  virtual_router_id 51
  priority 101
  authentication {
    auth_type PASS
    auth_pass 4be37dc3b4c90194d1600c483e10ad1d
  }
  virtual_ipaddress {
    ${virtualIpAddr}
  }
  track_script {
    check_apiserver
  }
}
EOF

  sudo bash -c 'cat > /etc/keepalived/check_apiserver.sh' <<EOF
#!/bin/sh
errorExit() {
  echo "*** \$*" 1>&2
  exit 1
}
curl --silent --max-time 2 --insecure https://localhost:6443/ -o /dev/null || errorExit "Error GET https://localhost:6443/"
if ip addr | grep -q ${virtualIpAddr}; then
    curl --silent --max-time 2 --insecure https://${virtualIpAddr}:6443/ -o /dev/null || errorExit "Error GET https://${virtualIpAddr}:6443/"
fi
EOF

  sudo systemctl enable keepalived.service
  sudo systemctl start keepalived.service
}

function kubeadmConfig() {
  cat > kubeadm-conf.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
kubernetesVersion: ${k8sVer}
controlPlaneEndpoint: "${virtualIpAddr}:6443"
etcd:
  external:
    endpoints:
      - https://${master1Ip}:2379
      - https://${master2Ip}:2379
      - https://${master3Ip}:2379
    caFile: ${etcdPath}/ca.pem
    certFile: ${etcdPath}/client.pem
    keyFile: ${etcdPath}/client-key.pem
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
apiServer:
  certSANs:
    - ${virtualIpAddr}
    - ${master1Ip}
    - ${master1Name}
    - ${master2Ip}
    - ${master2Name}
    - ${master3Ip}
    - ${master3Name}
  extraArgs:
    etcd-cafile: ${etcdPath}/ca.pem
    etcd-certfile: ${etcdPath}/client.pem
    etcd-keyfile: ${etcdPath}/client-key.pem
  timeoutForControlPlane: 4m0s
imageRepository: k8s.gcr.io
clusterName: "dc5tst-cluster"
EOF
}

function initMaster() {
  sudo sysctl net.bridge.bridge-nf-call-iptables=1
  sudo sysctl net.bridge.bridge-nf-call-ip6tables=1
  sudo swapoff -a
  sudo bash -c "sed -e 's:^\\(.*swap.*\\)$:# \\1:' -i /etc/fstab"
  setenforce 0
  sudo bash -c "sed 's/^SELINUX=enforcing$/SELINUX=permissive/' -i /etc/selinux/config"
  sudo kubeadm init --config kubeadm-conf.yaml --ignore-preflight-errors=all
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown "$(id -u)":"$(id -g)" $HOME/.kube/config
}

function syncPKI() {
for pkg in '*.key' '*.crt' '*.pub'; do
  sudo rsync -avzrlpgoDP \
             --rsync-path='sudo rsync' \
             root@${leadIP}:/etc/kubernetes/pki/${pkg} \
             /etc/kubernetes/pki/
done
  sudo rm -rf /etc/kubernetes/pki/apiserver*
  # sudo cp -r /root/etcd* /etc/kubernetes/pki/
}

function cniSetup() {
  kubectl apply -f \
          https://raw.githubusercontent.com/coreos/flannel/62e44c867a2846fefb68bd5f178daf4da3095ccb/Documentation/kube-flannel.yml
}

function teardown() {
  sudo kubeadm reset

  docker system prune -a -f
  sudo yum versionlock delete docker-ce
  sudo yum versionlock delete docker-ce-cli
  sudo yum versionlock delete kubeadm
  sudo yum versionlock delete kubelet
  sudo yum versionlock delete kubectl
  sudo yum versionlock delete kubernetes-cni

  sudo systemctrl disable docker.service
  sudo systemctrl disable kubectl.service

  sudo yum remove -y \
           docker-ce \
           docker-ce-cli \
           containerd.io \
           kubectl \
           kubeadm \
           kubelet \
           kubernetes-cni

  rm -rf /home/devops/.kube
  sudo rm -rf /var/log/pods/ \
              /var/log/containers/ \
              /etc/kubernetes/ \
              /var/lib/yum/repos/x86_64/7/kubernetes \
              /usr/libexec/kubernetes \
              /var/cache/yum/x86_64/7/kubernetes \
              /etc/systemd/system/multi-user.target.wants/kubelet.service  \
              /usr/lib/systemd/system/kubelet.service.d \
              /var/lib/kubelet \
              /usr/libexec/kubernetes

  sudo yum clean all
  sudo rm -rf /var/cache/yum
  sudo yum makecache
}

function setupLeadMaster() {
  sudo mkdir -p "${etcdPath}"
  certCA
  certClient
  certServerNPeer
  etcdService
  keepaliveSetup
  kubeadmConfig
  initMaster
  cniSetup
}

function setupFollowerMaster() {
  sudo mkdir -p "${etcdPath}"
  timeSync
  syncCert
  certServerNPeer
  etcdService
  keepaliveSetup
  kubeadmConfig
  syncPKI
  initMaster
  cniSetup
}
