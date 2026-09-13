// storage.bicep
// The shared mutable resource: one Storage Account with one blob container.
// Both sandboxes reach this over its public endpoint; nothing else connects them.

@description('Region.')
param location string

@description('Unique suffix for the global storage account name.')
param suffix string

@description('Blob container name.')
param blobContainerName string

@description('Cost-traceability tags, passed from main.bicep.')
param tags object = {}

// Storage account names: 3-24 chars, lowercase alphanumeric only.
var storageAccountName = toLower('ccstor${substring(suffix, 0, 12)}')

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false   // no anonymous access; sandboxes use the account key
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

var key = sa.listKeys().keys[0].value
var connectionString = 'DefaultEndpointsProtocol=https;AccountName=${sa.name};AccountKey=${key};EndpointSuffix=${environment().suffixes.storage}'

output storageAccountName string = sa.name
// NOTE: this output embeds the account key and is stored in deployment history.
// Acceptable for a throwaway testbed; a production system would use managed
// identity instead of keys. Worth citing in your Limitations section.
output connectionString string = connectionString
