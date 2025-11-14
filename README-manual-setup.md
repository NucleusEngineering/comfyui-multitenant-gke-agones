# ComfyUI on GKE Autopilot with Agones - Implementation Guide

This guide walks ComfyUI users through launching a scalable, managed deployment on GKE Autopilot, utilizing Filestore for shared model and output persistence.

For convenient multi-tenant management, we integrate the [Agones](https://agones.dev/site/) runtime operator. This setup ensures each isolated ComfyUI instance runs within its own dedicated Kubernetes Pod, which is allocated to an authorized user and can be configured with or without a GPU.

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

## Manual setup

```
PROJECT_ID=<replace this with your PROJECT ID>
SERVICE_ACCOUNT_EMAIL=<replace with the GCP's service account you want to use>
REGION=<replace this with your region>
DOMAIN_NAME=<replace with domain name you want to use>
GKE_CLUSTER_NAME=<replace this with your GKE cluster name>
GKE_NODE_NETWORK_TAG=<replace this with your GKE network tag>
VPC_NETWORK=<replace this with your VPC network name>
VPC_SUBNETWORK=<replace this with your VPC subnetwork name>
BUILD_REGIST=<replace this with your preferred Artifact Registry repository name>
FILESTORE_NAME=<replace with Filestore instance name>
FILESTORE_IP=<replace with Filestore IP address>
FILESTORE_ZONE=<replace with Filestore instance zone>
STATIC_IP_NAME=comfyui-agones-static-ip
```

### Create GKE Autopilot Cluster
```
# Create GKE cluster with workload identity enabled
gcloud container clusters create-auto ${GKE_CLUSTER_NAME} \
    --project=${PROJECT_ID} \
    --region=${REGION} \
    --network "projects/${PROJECT_ID}/global/networks/${VPC_NETWORK}" \
    --subnetwork "projects/${PROJECT_ID}/regions/${REGION}/subnetworks/${VPC_SUBNETWORK}" \
    --release-channel=regular
    --autoprovisioning-network-tags=${GKE_NODE_NETWORK_TAG}
    --enable-private-nodes
```

### Firewall rule setup for Agones
1. Since it's a private cluster, allow access from all internal CIDR(10.0.0.0/8, 172.16.0.0/16, 192.168.0.0/24). Specifically, CIDR range for pods is needed, but using all internal CIDRs will be easier.
2. TCP port 443/8080/8081 & 7000-8000 and UDP port 7000-8000
3. For Target use gke node tag ($GKE_NODE_NETWORK_TAG)

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
Update SERVICE_ACCOUNT_EMAIL with you service account for running your GKE cluster and run below command. We need access to Artifact Registry and also we need to bind GKE's SA to our GCP one.
```
gcloud artifacts repositories add-iam-policy-binding ${BUILD_REGIST} \
    --location=${REGION} \
    --member=serviceAccount:${SERVICE_ACCOUNT_EMAIL} \
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
gcloud filestore instances create ${FILESTORE_NAME} --zone=${FILESTORE_ZONE} --tier=BASIC_HDD --file-share=name=vol1,capacity=1TB --network=name=${VPC_NETWORK}
```
e.g. 
```
gcloud filestore instances create nfs-store --zone=europe-west4-b --tier=BASIC_HDD --file-share=name="vol1",capacity=1TB --network=name=${VPC_NETWORK}
```

Deploy the PV and PVC resource, replace the nfs-server-ip using the nfs instance's ip address that created before in the file pv.yaml.

### Install Agones
Install the Agones operator on default-pool, the default pool is long-run node pool that host the Agones Operator.
Note: for quick start, you can using the cloud shell which has helm installed already.
```
helm repo add agones https://agones.dev/chart/stable
helm repo update
kubectl create namespace agones-system
# Current agones setup require agones<=1.33.0
helm install comfyui-agones-release --namespace agones-system -f ./agones/values.yaml agones/agones --version 1.33.0
```

### Create Redis Cache
Create a redis cache instance to host the access information.
```
gcloud redis instances create --project=${PROJECT_ID}  comfyui-agones-cache --tier=standard --size=1 --region=${REGION} --redis-version=redis_7_2 --network=projects/${PROJECT_ID}/global/networks/${VPC_NETWORK} --connect-mode=DIRECT_PEERING

REDIS_HOST=$(gcloud redis instances describe comfyui-agones-cache --region ${REGION} --format=json | jq -r .host)
```

### Build Nginx proxy image
Build image with provided Dockerfile, push to repo in Artifact Registry. Please replace ${REDIS_HOST} in the nginx/comfyui.lua with the ip address record in previous step.

```
cd nginx
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
cd agones-sidecar
docker build . -t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/game-server:0.1
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/game-server:0.1
```
Or use Cloud Build.
```
gcloud builds submit \
--machine-type=e2-highcpu-32 \
--disk-size=100 \
--region=us-central1 \
-t ${REGION}-docker.pkg.dev/${PROJECT_ID}/${BUILD_REGIST}/game-server:0.1
```

## Setting GKE permissions
Update SERVICE_ACCOUNT_EMAIL with you service account for running your GKE cluster and run below command. We need access to Artifact Registry and also we need to bind GKE's SA to our GCP one.
```
gcloud artifacts repositories add-iam-policy-binding ${BUILD_REGIST} \
    --location=${REGION} \
    --member=serviceAccount:${SERVICE_ACCOUNT_EMAIL} \
    --role="roles/artifactregistry.reader"
```
For details, please refer to https://cloud.google.com/kubernetes-engine/docs/troubleshooting#permission_denied_error

### Create GKE cluster Service Account and bind with GCP's service account to be used with the GKE cluster
```
kubectl create sa comfyui-sa

gcloud iam service-accounts add-iam-policy-binding \
  ${SERVICE_ACCOUNT_EMAIL} \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[default/comfyui-sa]"

kubectl annotate serviceaccount comfyui-sa \
    --namespace default \
    iam.gke.io/gcp-service-account=genai3d-sa@dn-demos.iam.gserviceaccount.com  

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/artifactregistry.reader"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/file.editor"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/container.defaultNodeServiceAccount"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
    --role="roles/aiplatform.user"    
```

# Deploying everything on Kubernetes

To deploy ComfyUI agones deployment, please replace the image URL in the deployment.yaml and fleet yaml with the image built(nginx, optional agones-sidecar and comfyui) before.
```

FILESTORE_IP=$(gcloud filestore instances describe ${FILESTORE_NAME} --zone=europe-west3-b --format=json | jq '.networks[0].ipAddresses[0]')

cd agones

sed -i "s@<FILESTORE_IP>@${FILESTORE_IP}@g" pv.yaml
kubectl apply -f agones/pv.yaml
kubectl apply -f agones/pvc.yaml


sed -i "s@<REGION>@${REGION}@g" fleet-cpu.yaml
sed -i "s@<REGION>@${REGION}@g" fleet-gpu.yaml
sed -i "s@<PROJECT_ID>/<BUILD_REGIST>@${PROJECT_ID}/${BUILD_REGIST}@g" fleet-cpu.yaml
sed -i "s@<PROJECT_ID>/<BUILD_REGIST>@${PROJECT_ID}/${BUILD_REGIST}@g" fleet-gpu.yaml
cd -

cd nginx
sed -i "s@<REDIS_HOST>@${REDIS_HOST}@g" deployment.yaml
sed -i "s@<REGION>@${REGION}@g" deployment.yaml
sed -i "s@<PROJECT_ID>/<BUILD_REGIST>@${PROJECT_ID}/${BUILD_REGIST}@g" deployment.yaml
cd -

kubectl apply -f nginx/deployment.yaml
kubectl apply -f agones/role-bind.yaml
kubectl apply -f agones/fleet-cpu.yaml
kubectl apply -f agones/fleet-gpu.yaml
kubectl apply -f agones/fleet_autoscale.yaml
```

### Prepare Cloud Function Serverless VPC Access
Create serverless VPC access connector, which is used by cloud function to connect Redis through the private connection endpoint.
```
gcloud compute networks vpc-access connectors create comfyui-agones-connector --network ${VPC_NETWORK} --region ${REGION} --range 192.168.240.16/28
```

### Deploy Cloud Function cron job
This Cloud Function monitors the idle user, by default when the user is idle for 15mins, the ComfyUI runtime will be shut down back. To customize the idle timeout default setting, please overwrite the environemtn variable `TIME_INTERVAL`.
```
cd cloud-function
REDIS_HOST=$(gcloud redis instances describe comfyui-agones-cache --region ${REGION} --format=json | jq -r .host)
gcloud functions deploy redis_http --runtime python313 --trigger-http --allow-unauthenticated --region=${REGION} --vpc-connector=comfyui-agones-connector --egress-settings=private-ranges-only --set-env-vars=REDIS_HOST=${REDIS_HOST}
```
Record the Function trigger url.
```
FUNCTION_URL=$(gcloud functions describe redis_http --region ${REGION} --format=json | jq .url)
```
Create the task scheduler. Default location for the scheduler is `us-central1` but you can change to another region, just make sure it is supported.
```
gcloud scheduler jobs create http comfyui-agones-cron \
    --location=us-central1 \
    --schedule="*/5 * * * *" \
    --uri=${FUNCTION_URL}
```

### Deploy IAP(identity awared proxy)
To allocate isolated ComfyUI runtime and provide user access auth capability, we will use Google Cloud IAP service as an access gateway to provide the identity check and prograge the idenity to the ComfyUI backend.

Config the [OAuth consent screen](https://developers.google.com/workspace/guides/configure-oauth-consent) and [OAuth credentials](https://developers.google.com/workspace/guides/create-credentials#oauth-client-id), then configure [identity aware proxy for backend serivce on GKE](https://cloud.google.com/iap/docs/enabling-kubernetes-howto#oauth-configure).

After we create OAuth 2.0 Client IDs under OAuth credentials, we need to update the Client ID with "Authorized redirect URIs". Value looks something like this:
```
https://iap.googleapis.com/v1/oauth/clientIds/<xxx-xxx.apps.googleusercontent.com>:handleRedirect
```
where xxx-xxx.apps.googleusercontent.com is the Oauth 2.0 client ID you just created.

Create an static external ip address, record the ip address.
```
gcloud compute addresses create comfyui-agones-static-ip --global
gcloud compute addresses describe comfyui-agones-static-ip --global --format=json | jq .address
```

Now for BackendConfig configuration, replace the client_id and client_secret with the OAuth client created above.
```
kubectl create secret generic iap-secret --from-literal=client_id=${CLIENT_ID} \
    --from-literal=client_secret=${CLIENT_SECRET}
```
Change the DOMAIN_NAME in managed-cert.yaml with the your domain and then apply the configuration:
```
cd ingress-iap/
sed -i "s@<STATIC_IP_NAME>@${STATIC_IP_NAME}@g" ingress.yaml
sed -i "s@<DOMAIN_NAME>@${DOMAIN_NAME}@g" ingress.yaml
sed -i "s@<DOMAIN_NAME>@${DOMAIN_NAME}@g" managed-cert.yaml
cd ..
kubectl apply -f ./ingress-iap/managed-cert.yaml
kubectl apply -f ./ingress-iap/backendconfig.yaml
kubectl apply -f ./ingress-iap/service.yaml
kubectl apply -f ./ingress-iap/ingress.yaml
```
Give the authorized users required priviledge to access the service. [Guide](https://cloud.google.com/iap/docs/enabling-kubernetes-howto#iap-access) \
**Note: if you wish to add IAP users out of your organziation, set your application's "User Type" from "internal" to "external" in "Oauth consent screen".**

### Update DNS record for the domain
Update your DNS record by setting A record value to $(gcloud compute addresses describe comfyui-agones --global --format=json | jq .address) for the domain used in managed-cert.yaml
The Google-managed certificate won't be provisioned successfully unless the domain is already associated with the ingress external IP,
check out the [guide, see step 8](https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs)

### Access the service domain
Now you should be able to open your domain, login with IAP authorized account and access ComfyUI.

### Clean up
```
kubectl delete -f ./ingress-iap/managed-cert.yaml
kubectl delete -f ./ingress-iap/backendconfig.yaml
kubectl delete -f ./ingress-iap/service.yaml
kubectl delete -f ./ingress-iap/ingress.yaml

gcloud container clusters delete ${GKE_CLUSTER_NAME} --region=${REGION}

gcloud compute addresses delete comfyui-agones --global

gcloud scheduler jobs delete comfyui-agones-cron --location=us-central1
gcloud functions delete redis_http --region=${REGION} 

gcloud compute networks vpc-access connectors delete comfyui-agones-connector --region ${REGION} --async

gcloud artifacts repositories delete ${BUILD_REGIST} \
    --location=${REGION}$ --async

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
kubectl logs -f pod/comfyui-agones-fleet-xxxxx-xxxxx -c comfyui
```
2. Check stderr from nginx+lua deployment
```
kubectl logs -f deployment/comfyui-nginx-deployment
```
3. Check redis keys
Clear all keys from redis before reusing it for new deployment
```
redis-cli -h ${redis_host}
keys *
flushall
```
4. Check cloud scheduler & cloud function, the last run status should be "OK", otherwise check the logs.

### Why there is a simple-game-server container in the fleet?
This is an example game server from agones, we leverage it as a game server sdk to interact with agones control plane without additional coding and change to comfyui.
The nginx+lua will call simple-game-server to indirectly interact with agones for resource allocation and release.
