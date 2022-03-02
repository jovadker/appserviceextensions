#!/bin/bash

# Stop the script if any error occurs
set -e

echo "Deployment started"
echo "Location:$1 ResourceGroup:$2 Clustername:$3"


LOCATION=$1                 # the location of your cluster
RESOURCEGROUP=$2            # the name of the resource group where you want to create your cluster
CLUSTER=$3                 # the name of your cluster

az provider register -n Microsoft.RedHatOpenShift --wait

az group create \
  --name $RESOURCEGROUP \
  --location $LOCATION

az network vnet create \
   --resource-group $RESOURCEGROUP \
   --name aro-vnet \
   --address-prefixes 110.110.0.0/24

az network vnet subnet create \
   --resource-group $RESOURCEGROUP \
   --vnet-name aro-vnet \
   --name master-subnet \
   --address-prefixes 110.110.0.0/25 \
   --service-endpoints Microsoft.ContainerRegistry

az network vnet subnet create \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --name worker-subnet \
  --address-prefixes 110.110.0.128/25 \
  --service-endpoints Microsoft.ContainerRegistry

#Disable subnet private endpoint policies on the master subnet
az network vnet subnet update \
  --name master-subnet \
  --resource-group $RESOURCEGROUP \
  --vnet-name aro-vnet \
  --disable-private-link-service-network-policies true

echo "Create ARO:"
az aro create \
  --resource-group $RESOURCEGROUP \
  --name $CLUSTER \
  --vnet aro-vnet \
  --master-subnet master-subnet \
  --worker-subnet worker-subnet \
  --master-vm-size Standard_D8s_v3 \
  --worker-vm-size Standard_D4s_v3 \
  --worker-count 12

