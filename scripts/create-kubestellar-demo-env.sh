#!/usr/bin/env bash
# Copyright 2024 The KubeStellar Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Deploys Kubestellar environment for demo purposes on kind or k3d.

set -e

# Default Kubernetes platform parameter
k8s_platform="kind"

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --platform) k8s_platform="$2"; shift ;;
        -X) set -x ;;
        -h|--help)
            echo "Usage: $0 [--platform <kind|k3d>] [-X] [-h|--help]" >&2
            exit 0
            ;;
        *)
            echo "Unknown parameter passed: $1" >&2
            echo "Usage: $0 [--platform <kind|k3d>] [-X] [-h|--help]" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "$k8s_platform" != "kind" && "$k8s_platform" != "k3d" ]]; then
    echo "Invalid platform specified: $k8s_platform"
    echo "Supported platforms are: kind, k3d"
    exit 1
fi

echo "Selected Kubernetes platform: $k8s_platform"

echo -e "Checking container runtime..."
if ! dunsel=$(docker ps 2>&1); then
    echo "Error: The script cannot continue because Docker or Podman is not running. Please start your container runtime before running the script again."
    exit 1
fi
echo "Container runtime is running."

kubestellar_version=0.26.0-alpha.1
echo -e "KubeStellar Version: ${kubestellar_version}"

echo -e "Checking that pre-req softwares are installed..."
if [ "$k8s_platform" == "kind" ]; then
    curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/v${kubestellar_version}/hack/check_pre_req.sh | bash -s -- --assert -V kflex ocm helm kubectl docker kind
else
    # curl -s https://raw.githubusercontent.com/clubanderson/kubestellar/refs/heads/add-k3d-to-create-demo-env/hack/check_pre_req.sh | bash -s -- --assert -V kflex ocm helm kubectl docker k3d
    curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/refs/heads/main/hack/check_pre_req.sh | bash -s -- --assert -V kflex ocm helm kubectl docker k3d
fi

##########################################
cluster_clean_up() {
    error_message=$(eval "$1" 2>&1)
    if [ $? -ne 0 ]; then
        echo "clean up failed. Error:"
        echo "$error_message"
    fi
}

context_clean_up() {
    output=$(kubectl config get-contexts -o name)

    while IFS= read -r line; do
        if [ "$line" == "cluster1" ]; then
            echo "Deleting cluster1 context..."
            kubectl config delete-context cluster1

        elif [ "$line" == "cluster2" ]; then
            echo "Deleting cluster2 context..."
            kubectl config delete-context cluster2

        fi

    done <<< "$output"
}

checking_cluster() {
    found=false

    while true; do

        output=$(kubectl --context its1 get csr)

        while IFS= read -r line; do

            if echo "$line" | grep -q $1; then
                echo "$1 has been found, approving CSR"
                clusteradm --context its1 accept --clusters "$1"
                found=true
                break
            fi

        done <<< "$output"

        if [ "$found" = true ]; then
            break

        else
            echo "CSR for $1 not found. Trying again..."
            sleep 20
        fi

    done
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}
##########################################

echo -e "\nStarting environment clean up..."
echo -e "Starting cluster clean up..."

if command_exists "k3d"; then
    cluster_clean_up "k3d cluster delete kubeflex" &
    cluster_clean_up "k3d cluster delete cluster1" &
    cluster_clean_up "k3d cluster delete cluster2" &
    wait
fi
if command_exists "kind"; then
    cluster_clean_up "kind delete cluster --name kubeflex" &
    cluster_clean_up "kind delete cluster --name cluster1" &
    cluster_clean_up "kind delete cluster --name cluster2" &
    wait
fi

wait
echo -e "\033[33m✔\033[0m Cluster space clean up has been completed"

echo -e "\nStarting context clean up..."
context_clean_up
echo -e "\033[33m✔\033[0m Context space clean up completed"

echo -e "\nCreating two $k8s_platform clusters to serve as example WECs"
clusters=(cluster1 cluster2)
cluster_log_dir=$(mktemp -d)
trap "rm -rf $cluster_log_dir" EXIT
for cluster in "${clusters[@]}"; do
    if [ "$k8s_platform" == "kind" ]; then
        kind create cluster --name "${cluster}" >"${cluster_log_dir}/${cluster}.log" 2>&1 && touch "${cluster_log_dir}/${cluster}.success" &
    else
        k3d cluster create --network k3d-kubeflex "${cluster}" >"${cluster_log_dir}/${cluster}.log" 2>&1 && touch "${cluster_log_dir}/${cluster}.success" &
        wait
    fi
done

echo -e "Creating KubeFlex cluster with SSL Passthrough"
if [ "$k8s_platform" == "kind" ]; then
    curl -s https://raw.githubusercontent.com/kubestellar/kubestellar/v${kubestellar_version}/scripts/create-kind-cluster-with-SSL-passthrough.sh | bash -s -- --name kubeflex --nosetcontext
else
    k3d cluster create -p "9443:443@loadbalancer" --k3s-arg "--disable=traefik@server:*" kubeflex
    sleep 15
    helm install ingress-nginx ingress-nginx --set "controller.extraArgs.enable-ssl-passthrough=" --repo https://kubernetes.github.io/ingress-nginx --version 4.11.3 --namespace ingress-nginx --create-namespace
fi
echo -e "\033[33m✔\033[0m Completed KubeFlex cluster with SSL Passthrough"

wait
kubectl config use-context $k8s_platform-kubeflex

some_failed=false
for cluster in "${clusters[@]}"; do
    if ! [ -f "${cluster_log_dir}/${cluster}.success" ]; then
	echo -e "\033[0;31mX\033[0m Creation of cluster $cluster failed!" >&2
	cat "${cluster_log_dir}/${cluster}.log" >&2
	some_failed=true
	continue
    fi
    echo -e "\033[33m✔\033[0m Cluster $cluster was successfully created"
    kubectl config rename-context "${k8s_platform}-${cluster}" "${cluster}" >/dev/null 2>&1
done
if [ "$some_failed" = true ]; then exit 10; fi

for cluster in "${clusters[@]}"; do
  if kubectl config get-contexts | grep -w " ${cluster} " >/dev/null 2>&1; then
    echo -e "\033[33m✔\033[0m $cluster context exists."
  else
    if kubectl config rename-context "${k8s_platform}-${cluster}" "${cluster}" >/dev/null 2>&1; then
      echo -e "\033[33m✔\033[0m Renamed context '${k8s_platform}-${cluster}' to '${cluster}'."
    else
      echo -e "Failed to rename context '${k8s_platform}-${cluster}' to '${cluster}'. It may not exist."
    fi
  fi
done

echo -e "\nPulling container images local..."
images=("ghcr.io/loft-sh/vcluster:0.16.4"
        "rancher/k3s:v1.27.2-k3s1"
        "quay.io/open-cluster-management/registration-operator:v0.13.2"
        "docker.io/bitnami/postgresql:16.0.0-debian-11-r13")

for image in "${images[@]}"; do
    (
        docker pull "$image"
    ) &
done
wait

for image in "${images[@]}"; do
    if [ "$k8s_platform" == "kind" ]; then
        kind load docker-image "$image" --name kubeflex
    else
        k3d image import "$image" --cluster kubeflex
    fi
done

echo -e "\nStarting the process to install KubeStellar core: $k8s_platform-kubeflex..."
if [ "$k8s_platform" == "k3d" ]; then
    helm upgrade --install ks-core oci://ghcr.io/kubestellar/kubestellar/core-chart \
        --version $kubestellar_version \
        --set-json='ITSes=[{"name":"its1"}]' \
        --set-json='WDSes=[{"name":"wds1"},{"name":"wds2", "type":"host"}]' \
        --set-json='verbosity.default=5' \
        --set kubeflex-operator.hostContainer=k3d-kubeflex-server-0
else
    helm upgrade --install ks-core oci://ghcr.io/kubestellar/kubestellar/core-chart \
        --version $kubestellar_version \
        --set-json='ITSes=[{"name":"its1"}]' \
        --set-json='WDSes=[{"name":"wds1"},{"name":"wds2", "type":"host"}]' \
        --set-json='verbosity.default=5'
fi

kflex ctx --set-current-for-hosting # make sure the KubeFlex CLI's hidden state is right for what the Helm chart just did
kflex ctx --overwrite-existing-context wds1
kflex ctx --overwrite-existing-context wds2
kflex ctx --overwrite-existing-context its1

echo -e "\nWaiting for OCM cluster manager to be ready..."
kubectl --context $k8s_platform-kubeflex wait controlplane.tenancy.kflex.kubestellar.org/its1 --for 'jsonpath={.status.postCreateHooks.its-with-clusteradm}=true' --timeout 24h
kubectl --context $k8s_platform-kubeflex wait -n its1-system job.batch/its-with-clusteradm --for condition=Complete --timeout 24h
echo -e "\nWaiting for OCM hub cluster-info to be updated..."
kubectl --context $k8s_platform-kubeflex wait -n its1-system job.batch/update-cluster-info --for condition=Complete --timeout 24h
echo -e "\033[33m✔\033[0m OCM hub is ready"

echo -e "\nRegistering cluster 1 and 2 for remote access with KubeStellar Core..."

: set flags to "" if you have installed KubeStellar on an OpenShift cluster
flags="--force-internal-endpoint-lookup"
clusters=(cluster1 cluster2);
for cluster in "${clusters[@]}"; do
   clusteradm --context its1 get token | grep '^clusteradm join' | sed "s/<cluster_name>/${cluster}/" | awk '{print $0 " --context '${cluster}' --singleton '${flags}'"}' | sh
done

echo -e "Checking that the CSR for cluster 1 and 2 appears..."

echo""
echo "Waiting for cluster1 and cluster2 to be ready and then approve their CSRs"
checking_cluster cluster1
checking_cluster cluster2

echo""
echo "Checking the new clusters are in the OCM inventory and label them"
kubectl --context its1 get managedclusters
kubectl --context its1 label managedcluster cluster1 location-group=edge name=cluster1
kubectl --context its1 label managedcluster cluster2 location-group=edge name=cluster2
echo""
echo -e "\033[33m✔\033[0m Congratulations! Your KubeStellar demo environment is now ready to use."

cat <<EOF

Be sure to execute the following commands to set the shell variables expected in the example scenarios.

host_context=${k8s_platform}-kubeflex
its_cp=its1
its_context=its1
wds_cp=wds1
wds_context=wds1
wec1_name=cluster1
wec2_name=cluster2
wec1_context=\$wec1_name
wec2_context=\$wec2_name
label_query_both=location-group=edge
label_query_one=name=cluster1
EOF
