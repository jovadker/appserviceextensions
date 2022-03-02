#!/bin/bash

# Stop the script if any error occurs
set -e

echo "Deployment started"
echo "Location:$1 AKSRG:$2 Clustername:$3 arcName: $4 arcResourceGroup: $5 spnobjectid: $6"

location=$1
resourceGroup=$2
aksClusterName=$3
arcName=$4
arcResourceGroup=$5
spnobjectid=$6
customLocationName="${arcResourceGroup//./}-location" # ohcontainersarc-location" # Name of the custom location
# make location name lowercase
customLocationName="${customLocationName,,}"
echo "Custom Location: $customLocationName"

kubeEnvironmentName="${arcResourceGroup//./}-kubeenvironment" # Name of the App Service Kubernetes environment resource
echo "Kube Environment: $kubeEnvironmentName"


# https://docs.microsoft.com/en-us/azure/app-service/manage-create-arc-environment?tabs=bash

az extension add --upgrade --yes --name connectedk8s
az extension add --upgrade --yes --name k8s-extension
az extension add --upgrade --yes --name customlocation
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.Web --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az extension add --upgrade --yes --name appservice-kube

# Get kube.config for existing AKS cluster
az aks get-credentials --resource-group $resourceGroup --name $aksClusterName --admin
kubelogin convert-kubeconfig -l azurecli

# Azure Arc resource group
az group create -g $arcResourceGroup -l $location

# Create Azure Arc connected cluster
# https://docs.microsoft.com/en-us/azure/azure-arc/kubernetes/troubleshooting#enable-custom-locations-using-service-principal
#arcservicespnobjectid=$(az ad sp show --id bc313c14-388c-4e7d-a58e-70017303ee3b --query objectId -o tsv)
arcClusterName="${arcResourceGroup}-cluster" # Name of the connected cluster resource
az connectedk8s connect --resource-group $arcResourceGroup --name $arcClusterName #--custom-locations-oid $arcservicespnobjectid --debug
#Validate result
az connectedk8s show --resource-group $arcResourceGroup --name $arcClusterName

#LAW workspace - DISABLED 
if [ "!!" == "[]" ]; then
    workspaceName="arc-workspace" # Name of the Log Analytics workspace
    workspaceExist=$(az monitor log-analytics workspace list -g $arcResourceGroup --query "[?name=='$workspaceName'].{Name:name}")
    if [ "$workspaceExist" == "[]" ]; then
        az monitor log-analytics workspace create \
            --resource-group $arcResourceGroup \
            --workspace-name $workspaceName
        
    else
        echo "Workspace $workspaceName already exists"
    fi
    logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show \
            --resource-group $arcResourceGroup \
            --workspace-name $workspaceName \
            --query customerId \
            --output tsv)
    logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64 -w0) # Needed for the next step
    logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys \
            --resource-group $arcResourceGroup \
            --workspace-name $workspaceName \
            --query primarySharedKey \
            --output tsv)
    logAnalyticsKeyEnc=$(printf %s $logAnalyticsKey | base64 -w0) # Needed for the next step
fi
# Install the App Service Extension
extensionName="appservice-ext" # Name of the App Service extension
namespace="appservice-ns" # Namespace in your cluster to install the extension and provision resources

echo "Installing the App Service Extension"
az k8s-extension create \
    --resource-group $arcResourceGroup \
    --name $extensionName \
    --cluster-type connectedClusters \
    --cluster-name $arcClusterName \
    --extension-type 'Microsoft.Web.Appservice' \
    --release-train stable \
    --auto-upgrade-minor-version true \
    --scope cluster \
    --release-namespace $namespace \
    --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" \
    --configuration-settings "appsNamespace=${namespace}" \
    --configuration-settings "clusterName=${kubeEnvironmentName}" \
    --configuration-settings "keda.enabled=true" \
    --configuration-settings "buildService.storageClassName=default" \
    --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" \
    --configuration-settings "customConfigMap=${namespace}/kube-environment-config" \
    --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=${arcResourceGroup}" #\
    #--configuration-settings "logProcessor.appLogs.destination=log-analytics" \
    #--configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=${logAnalyticsWorkspaceIdEnc}" \
    #--configuration-protected-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=${logAnalyticsKeyEnc}"

echo "Getting the extension id"
extensionId=$(az k8s-extension show \
    --cluster-type connectedClusters \
    --cluster-name $arcClusterName \
    --resource-group $arcResourceGroup \
    --name $extensionName \
    --query id \
    --output tsv)

echo "Wait for the extension to be ready"
az resource wait --ids $extensionId --custom "properties.installState!='Pending'" --api-version "2020-07-01-preview"

# Create Custom location
#az connectedk8s enable-features -n $aksClusterName -g $resourceGroup --custom-locations-oid $arcservicespnobjectid --features cluster-connect custom-locations --debug
echo "Creating custom location"
customlocationexist=$(az customlocation list -g $arcResourceGroup --query "[?name=='$customLocationName'].{Name:name}")
echo "customlocationexist: $customlocationexist"
if [ "$customlocationexist" == "[]" ]; then
    echo "Custom location doesn't exist: $customLocationName"
    connectedClusterId=$(az connectedk8s show --resource-group $arcResourceGroup --name $arcClusterName --query id --output tsv)
    az customlocation create \
        --resource-group $arcResourceGroup \
        --name $customLocationName \
        --host-resource-id $connectedClusterId \
        --namespace $namespace \
        --cluster-extension-ids $extensionId
fi

echo "Creating kube-environment"
kubeenvexist=$(az appservice kube list -g $arcResourceGroup --query "[?name=='$kubeEnvironmentName'].{Name:name}")
if [ "$kubeenvexist" == "[]" ]; then
    echo "kube-environment doesn't exist: $kubeEnvironmentName"
    # Create App Service Kubernetes Environment
    customLocationId=$(az customlocation show \
        --resource-group $arcResourceGroup \
        --name $customLocationName \
        --query id \
        --output tsv)

    az appservice kube create \
        --resource-group $arcResourceGroup \
        --name $kubeEnvironmentName \
        --custom-location $customLocationId
fi

# Custom WebApp resource group
webappgroupName="${arcResourceGroup}.webapps" # Name of resource group for the connected cluster
az group create -g $webappgroupName -l $location
