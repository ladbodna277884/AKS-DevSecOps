// ----------------------
// Params (kept as-is)
// ----------------------
@description('The unique DNS prefix for your cluster, such as myakscluster. This cannot be updated once the Managed Cluster has been created.')
param dnsPrefix string = resourceGroup().name

@description('The unique name for the AKS cluster, such as myAKSCluster.')
param clusterName string = 'devsecops-aks'

@description('The unique name for the Azure Key Vault.')
param akvName string = 'akv-${uniqueString(resourceGroup().id)}'

@description('The region to deploy the cluster. Defaults to the resource group location.')
param location string = resourceGroup().location

@minValue(1)
@maxValue(50)
@description('Number of agents (VMs) to host containers.')
param agentCount int = 1

@description('Default node size.')
param agentVMSize string = 'Standard_B2s'

// ----------------------
// ACR (Standard)
// ----------------------
resource acr 'Microsoft.ContainerRegistry/registries@2025-05-01-preview' = {
  name: 'acr${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    adminUserEnabled: false // more secure than true
  }
}

// ----------------------
// AKS (Managed Identity + AAD RBAC)
// ----------------------
resource aks 'Microsoft.ContainerService/managedClusters@2025-05-01' = {
  name: clusterName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    // Minimal system pool
    agentPoolProfiles: [
      {
        name: 'systempool'
        mode: 'System'
        count: agentCount
        vmSize: agentVMSize
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]

    // Enable modern Entra ID integration + Azure RBAC
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      // tenantID defaults to the deployment tenant if omitted; keep it implicit
    }

    // Optional: keep default (Kubenet). Uncomment to force Azure CNI:
    // networkProfile: {
    //   networkPlugin: 'azure'
    // }
  }
}

// ----------------------
// Key Vault (RBAC or Access Policies)
// ----------------------
resource akv 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: akvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // If you prefer Azure RBAC for data-plane auth:
    // enableRbacAuthorization: true
    // accessPolicies: []
    //
    // If you want to keep access policies (legacy model), leave enableRbacAuthorization unset
    // and keep an allowlist for the AKS control plane identity (not kubelet).
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: aks.identity.principalId
        permissions: {
          keys: [ 'get' ]
          secrets: [ 'get' ]
        }
      }
    ]
    // Recommended hardening (optional):
    // enableSoftDelete: true // default on in most regions
    // enablePurgeProtection: true
  }
}

// ----------------------
// RBAC: Give AKS kubelet identity AcrPull on ACR
// (works whether AKS creates its own kubelet UAMI or you supply one)
// ----------------------

// Built-in AcrPull role definition GUID
var acrPullRoleDefId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

// Give the AKS kubelet identity AcrPull on ACR
resource acrAksAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.name, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefId
    // was: aks.properties.identityProfile['kubeletidentity'].objectId
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
  }
}

// ----------------------
// Outputs
// ----------------------
output controlPlaneFQDN string = aks.properties.fqdn
