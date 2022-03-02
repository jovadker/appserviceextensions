#!/bin/bash

# Stop the script if any error occurs
set -e

echo "Deployment started"

echo "Location:$1 RG:$2 Clustername:$3 ACR: $4"

location=$1
resourceGroup=$2
aksClusterName=$3
acrName=$4

aadAdminGroupId="XXXXXXXX-DDDD-EEEE-FFFF-12345678901"
systemNodePoolName="systempool"

az group create --name $resourceGroup --location $location

acrexist=$(az acr list -g $resourceGroup --query "[?name=='$acrName'].{Name:name}")
if [ "$acrexist" == "[]" ]; then
    az acr create --sku Basic -g $resourceGroup -n $acrName 
fi

# in the form of /subscriptions/id/resourceGroups/rg/providers/Microsoft.ContainerRegistry/registries/ecommerceRegistry
acrnameFullPath=$(az acr show --name $acrName --query id --output tsv)
echo "ACR name full path: $acrnameFullPath"

az aks create \
    --resource-group $resourceGroup \
    --name $aksClusterName \
    --min-count 1 \
    --node-count 1 \
    --max-count 3 \
    --enable-cluster-autoscaler \
    --kubernetes-version 1.22.6 \
    --load-balancer-sku standard \
    --enable-managed-identity \
    --no-ssh-key \
    --max-pods 100 \
    --node-vm-size Standard_B4ms \
    --attach-acr $acrnameFullPath \
    --enable-aad \
    --network-plugin kubenet \
    --nodepool-name $systemNodePoolName \
    --aad-admin-group-object-ids $aadAdminGroupId \
    --node-osdisk-type Ephemeral \
    --node-osdisk-size 32 \
    --enable-addons azure-policy \
    --network-policy calico

az aks enable-addons --addons azure-policy --name $aksClusterName --resource-group $resourceGroup