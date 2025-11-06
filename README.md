# ComfyUI on Agones Implementation Guide

This guide give simple steps for ComfyUI users to launch a ComfyUI deployment by using GCP GKE service, and using Filestore as shared storage for model and output files. For convinent multi-user ComfyUI runtime management, using the [Agones](https://agones.dev/site/) as the runtime management operator, each isolated ComfyUI runtime is hosted in an isolated POD, each authorized user will be allocated a dedicated POD. User can just follow the step have your ComfyUI model running.

* [Introduction](#Introduction)
* [How-To](#how-to)

## Introduction
   This project is using the [ComfyUI](https://github.com/AUTOMATIC1111/ComfyUI) open source as the user interactive front-end, customer can just prepare the ComfyUI model to build/deployment ComfyUI model by container. This project use the cloud build to help you quick build up a docker image with your ComfyUI model, then you can make a deployment base on the docker image. To give mutli-user isolated comfyui runtime, using the [Agones](https://agones.dev/site/) as the ComfyUI fleet management operator, Agones manage the comfyui runtime's lifecycle and control the autoscaling based on user demand.

## Architecture
![comfyui-agones-arch](images/comfyui-agones-arch.png)

## How To
you can use the cloud shell as the run time to do below steps.
### Before you begin
1. Make sure you have an available GCP project for your deployment
2. Enable the required service API using [cloud shell](https://cloud.google.com/shell/docs/run-gcloud-commands)
```
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com container.googleapis.com file.googleapis.com vpcaccess.googleapis.com redis.googleapis.com cloudscheduler.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com
```
3. Exempt below organization policy constraints in your project
```
constraints/compute.vmExternalIpAccess
constraints/compute.requireShieldedVm  
constraints/cloudfunctions.allowedIngressSettings
constraints/iam.allowedPolicyMemberDomains(optional)
```
### Initialize the environment

```
PROJECT_ID=<replace this with your PROJECT ID>
GKE_CLUSTER_NAME=<replace this with your GKE cluster name>
REGION=<replace this with your region>
VPC_NETWORK=<replace this with your VPC network name>
VPC_SUBNETWORK=<replace this with your VPC subnetwork name>
BUILD_REGIST=<replace this with your preferred Artifact Registry repository name>
FILESTORE_NAME=<replace with Filestore instance name>
FILESTORE_ZONE=<replace with Filestore instance zone>
FILESHARE_NAME=<replace with fileshare name>
```
### Create GKE Cluster
Do the following step using the cloud shell. This guide using the T4 GPU node as the VM host, by your choice you can change the node type with [other GPU instance type](https://cloud.google.com/compute/docs/gpus). \
In this guide we also by default enabled [Filestore CSI driver](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/filestore-csi-driver) for models/outputs sharing. \

```
# Create GKE cluster with workload identity enabled
gcloud container clusters create-auto ${GKE_CLUSTER_NAME} \
    --project=${PROJECT_ID} \
    --region=${REGION} \
    --network "projects/${PROJECT_ID}/global/networks/${VPC_NETWORK}" \
    --subnetwork "projects/${PROJECT_ID}/regions/${REGION}/subnetworks/${VPC_SUBNETWORK}" \
    --release-channel=regular \
    --enable-managed-prometheus

# For existing cluster,
gcloud container clusters update ${GKE_CLUSTER_NAME} \
    --region=${REGION} \
    --workload-pool="${PROJECT_ID}.svc.id.goog"
```

### Firewall rule setup for Agones
1. For public cluster, allow 0.0.0.0/0
2. For private cluster, allow access from all internal CIDR(10.0.0.0/8, 172.16.0.0/16, 192.168.0.0/24). Specifically, CIDR range for pod, but using all internal CIDR will be easier.
3. TCP port 443/8080/8081 & 7000-8000 and UDP port 7000-8000
4. For Target use gke node tag as target tag, e.g. gke-gke-01-7267dc32-node, you can find it in your VM console.

**Note: for private cluster, a Cloud NAT is required for the GKE subnet. comfyui need access to internet to automatically download necessary model files**

```
gcloud compute firewall-rules create allow-agones \
	--direction=INGRESS --priority=1000 --network=${VPC_NETWORK} --action=ALLOW \
	--rules=tcp:443,tcp:8080,tcp:8081,tcp:7000-8000,udp:7000-8000 \
	--source-ranges=0.0.0.0/0 \
	--target-tags=${GKE_NODE_NETWORK_TAG}
```

### Get credentials of GKE cluster
```
gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --region ${REGION}
```

### GPU Driver Installation
With GKE Autopilot, you don't need to manually install NVIDIA GPU drivers. Autopilot automatically manages the installation of the appropriate drivers when you request GPU resources in your workload specifications.

### Create Artifact Registry as Docker Repo
```
gcloud artifacts repositories create ${BUILD_REGIST} --repository-format=docker \
--location=${REGION}

gcloud auth configure-docker ${REGION}-docker.pkg.dev
```

### Grant the GKE cluster with Artifact Registry read access
By default, GKE cluster is using default compute engine service account to access Artifacts registry.
Update SERVICE_ACCOUNT_EMAIL with you default compute engine service account and run below command.
```
gcloud artifacts repositories add-iam-policy-binding ${BUILD_REGIST} \
    --location=${REGION} \
    --member=serviceAccount:SERVICE_ACCOUNT_EMAIL \
    --role="roles/artifactregistry.reader"
```
For details, please refer to https://cloud.google.com/kubernetes-engine/docs/troubleshooting#permission_denied_error

### Build ComfyUI Image
Build image with provided Dockerfile, push to repo in Artifact Registry

```
cd comfyui
docker build . -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-gke:0.1
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-gke:0.1

```
You can also build it with Cloud Build.
```
gcloud builds submit \
--machine-type=e2-highcpu-32 \
--disk-size=100 \
--region=us-central1 \
-t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-gke:0.1
```

### Create Filestore
Create Filestore storage, mount and prepare files and folders for models/outputs/training data
You should prepare a VM to mount the filestore instance.

```
gcloud filestore instances create ${FILESTORE_NAME} --zone=${FILESTORE_ZONE} --tier=BASIC_HDD --file-share=name=${FILESHARE_NAME},capacity=1TB --network=name=${VPC_NETWORK}
e.g. 
gcloud filestore instances create nfs-store --zone=us-central1-b --tier=BASIC_HDD --file-share=name="vol1",capacity=1TB --network=name=${VPC_NETWORK}

```
Deploy the PV and PVC resource, replace the nfs-server-ip using the nfs instance's ip address that created before in the file nfs_pv.yaml.
Update the "path: /vol1" with fileshare created with the filestore. The yaml file is located in ./ComfyUI-UI-Agones/agones/ folder.
```
kubectl apply -f ./ComfyUI-UI-Agones/agones/nfs_pv.yaml
kubectl apply -f ./ComfyUI-UI-Agones/agones/nfs_pvc.yaml
```

### Install Agones
Install the Agones operator on default-pool, the default pool is long-run node pool that host the Agones Operator.
Note: for quick start, you can using the cloud shell which has helm installed already.
```
helm repo add agones https://agones.dev/chart/stable
helm repo update
kubectl create namespace agones-system
cd ComfyUI-on-GCP/ComfyUI-UI-Agones
# Current agones setup require agones<=1.33.0
helm install comfyui-agones-release --namespace agones-system -f ./agones/values.yaml agones/agones --version 1.33.0
```

### Create Redis Cache
Create a redis cache instance to host the access information.
```
gcloud redis instances create --project=${PROJECT_ID}  comfyui-agones-cache --tier=standard --size=1 --region=${REGION} --redis-version=redis_6_x --network=projects/${PROJECT_ID}/global/networks/${VPC_NETWORK} --connect-mode=DIRECT_PEERING
```

Record the redis instance connection ip address.
```
gcloud redis instances describe comfyui-agones-cache --region ${REGION} --format=json | jq .host
```

### Build Nginx proxy image
Build image with provided Dockerfile, push to repo in Artifact Registry. Please replace ${REDIS_HOST} in the nginx/comfyui.lua with the ip address record in previous step.

```
cd ComfyUI-on-GCP/ComfyUI-UI-Agones/nginx
REDIS_IP=$(gcloud redis instances describe comfyui-agones-cache --region ${REGION} --format=json 2>/dev/null | jq .host)
sed -i "s@\"\${REDIS_HOST}\"@${REDIS_IP}@g" comfyui.lua

docker build . -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-nginx:0.1
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-nginx:0.1
```
Or use Cloud Build.
```
gcloud builds submit \
--machine-type=e2-highcpu-32 \
--disk-size=100 \
--region=us-central1 \
-t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-nginx:0.1
```

### Build agones-sidecar image
Build the optional agones-sidecar image with provided Dockerfile, push to repo in Artifact Registry. This is to hijack the 502 returned from comfyui before it finished launching to provide a graceful experience.

```
cd ComfyUI-on-GCP/ComfyUI-UI-Agones/agones-sidecar
docker build . -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-agones-sidecar:0.1
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-agones-sidecar:0.1
```
Or use Cloud Build.
```
gcloud builds submit \
--machine-type=e2-highcpu-32 \
--disk-size=100 \
--region=us-central1 \
-t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/comfyui-agones-sidecar:0.1
```

### Deploy ComfyUI agones deployment(Filestore CSI)
Deploy ComfyUI agones deployment, please replace the image URL in the deployment.yaml and fleet yaml with the image built(nginx, optional agones-sidecar and comfyui) before.
```
cd ComfyUI-on-GCP/ComfyUI-UI-Agones/agones
sed -i "s@<REGION>@${REGION}@g" fleet_pvc.yaml
sed -i "s@<PROJECT_ID>/<BUILD_REGIST>@${PROJECT_ID}/${BUILD_REGIST}@g" fleet_pvc.yaml
cd -

cd ComfyUI-on-GCP/ComfyUI-UI-Agones/nginx
sed -i "s@<REGION>@${REGION}@g" deployment.yaml
sed -i "s@<PROJECT_ID>/<BUILD_REGIST>@${PROJECT_ID}/${BUILD_REGIST}@g" deployment.yaml
cd -

kubectl apply -f ComfyUI-on-GCP/ComfyUI-UI-Agones/nginx/deployment.yaml
kubectl apply -f ComfyUI-on-GCP/ComfyUI-UI-Agones/agones/fleet_pvc.yaml
kubectl apply -f ComfyUI-on-GCP/ComfyUI-UI-Agones/agones/fleet_autoscale.yaml
```

### Prepare Cloud Function Serverless VPC Access
Create serverless VPC access connector, which is used by cloud function to connect Redis through the private connection endpoint.
```
gcloud compute networks vpc-access connectors create comfyui-agones-connector --network ${VPC_NETWORK} --region ${REGION} --range 192.168.240.16/28
```

### Deploy Cloud Function Cruiser Program
This Cloud Function work as Cruiser to monitor the idle user, by default when the user is idle for 15mins, the ComfyUI runtime will be collected back. Please replace ${REDIS_HOST} with the redis instance ip address that record in previous step. To custom the idle timeout default setting, please overwrite setting by setting the variable TIME_INTERVAL.
```
cd ComfyUI-on-GCP/ComfyUI-UI-Agones/cloud-function
REDIS_HOST=$(gcloud redis instances describe comfyui-agones-cache --region ${REGION} --format=json 2>/dev/null | jq .host)
gcloud functions deploy redis_http --runtime python310 --trigger-http --allow-unauthenticated --region=${REGION} --vpc-connector=comfyui-agones-connector --egress-settings=private-ranges-only --set-env-vars=REDIS_HOST=${REDIS_HOST}
```
Record the Function trigger url.
```
gcloud functions describe redis_http --region us-central1 --format=json | jq .httpsTrigger.url
```
Create the cruiser scheduler. Please change ${FUNCTION_URL} with url in previous step.
```
gcloud scheduler jobs create http comfyui-agones-cruiser \
    --location=${REGION} \
    --schedule="*/5 * * * *" \
    --uri=${FUNCTION_URL}
```

### Deploy IAP(identity awared proxy)
To allocate isolated ComfyUI runtime and provide user access auth capability, using the Google Cloud IAP service as an access gateway to provide the identity check and prograge the idenity to the ComfyUI backend.

Config the [OAuth consent screen](https://developers.google.com/workspace/guides/configure-oauth-consent) and [OAuth credentials](https://developers.google.com/workspace/guides/create-credentials#oauth-client-id), then configure [identity aware proxy for backend serivce on GKE](https://cloud.google.com/iap/docs/enabling-kubernetes-howto#oauth-configure).

After created OAuth 2.0 Client IDs under OAuth credentials, update the Client ID with "Authorized redirect URIs", value should be like,
```
https://iap.googleapis.com/v1/oauth/clientIds/<xxx-xxx.apps.googleusercontent.com>:handleRedirect
```
where xxx-xxx.apps.googleusercontent.com is the Oauth 2.0 client ID you just created.

Create an static external ip address, record the ip address.
```
gcloud compute addresses create comfyui-agones --global
gcloud compute addresses describe comfyui-agones --global --format=json | jq .address
```

Config BackendConfig, replace the client_id and client_secret with the OAuth client create before.
```
kubectl create secret generic iap-secret --from-literal=client_id=${client_id_key} \
    --from-literal=client_secret=${client_secret_key}
```
Change the DOMAIN_NAME1 in managed-cert.yaml with the environment domain, then deploy the depend resources.
```
kubectl apply -f ./ingress-iap/managed-cert.yaml
kubectl apply -f ./ingress-iap/backendconfig.yaml
kubectl apply -f ./ingress-iap/service.yaml
kubectl apply -f ./ingress-iap/ingress.yaml
```
Give the authorized users required priviledge to access the service. [Guide](https://cloud.google.com/iap/docs/enabling-kubernetes-howto#iap-access) \
**Note: if you wish to add IAP users out of your organziation, set your application's "User Type" from "internal" to "external" in "Oauth consent screen".**

### Update DNS record for the domain
Update your DNS record, set A record value to $(gcloud compute addresses describe comfyui-agones --global --format=json | jq .address) for the domain used in managed-cert.yaml
The Google-managed certificate won't be provisioned successfully unless the domain is already associated with the ingress external IP,
check out the [guide, see step 8](https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs)

### Access the service domain
Use accounts setup with IAP access to access service domain.

### Clean up
```
kubectl delete -f ./ingress-iap/managed-cert.yaml
kubectl delete -f ./ingress-iap/backendconfig.yaml
kubectl delete -f ./ingress-iap/service.yaml
kubectl delete -f ./ingress-iap/ingress.yaml

gcloud container clusters delete ${GKE_CLUSTER_NAME} --region=${REGION_NAME}

gcloud compute addresses delete comfyui-agones --global

gcloud scheduler jobs delete comfyui-agones-cruiser --location=${REGION}
gcloud functions delete redis_http --region=${REGION} 

gcloud compute networks vpc-access connectors delete comfyui-agones-connector --region ${REGION} --async

gcloud artifacts repositories delete ${BUILD_REGIST} \
    --location=us-central1 --async

gcloud redis instances delete --project=${PROJECT_ID} comfyui-agones-cache --region ${REGION}
gcloud filestore instances delete ${FILESTORE_NAME} --zone=${FILESTORE_ZONE}
```


## FAQ
### How could I troubleshooting if I get 502?
It is normal if you get 502 before pod is ready, you may have to wait for a few minutes for containers to be ready(usually less than 10mins), then refresh the page.
If it is much longer then expected, then

1. Check stdout/stderr from pod
To see if comfyui has been launched successfully
```
kubectl logs -f pod/comfyui-agones-fleet-xxxxx-xxxxx -c ComfyUI
```
2. Check stderr from nginx+lua deployment
```
kubectl logs -f deployment.apps/ComfyUI-nginx-deployment
```
3. Check redis keys
Clear all keys from redis before reusing it for new deployment
```
redis-cli -h ${redis_host}
keys *
flushdb
```
4. Check cloud scheduler & cloud function, the last run status should be "OK", otherwise check the logs.

### Why there is a simple-game-server container in the fleet?
This is an example game server from agones, we leverage it as a game server sdk to interact with agones control plane without additional coding and change to comfyui.
The nginx+lua will call simple-game-server to indirectly interact with agones for resource allication and release.
