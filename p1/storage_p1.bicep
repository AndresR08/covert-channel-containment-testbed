// storage_p1.bicep
// P1 n-party experiment: the shared mutable resource.
// Same configuration as storage.bicep (S1); duplicated rather than modified so
// the S1 base files stay untouched.

param location string
param suffix string
param tags object = {}

var storageAccountName = toLower('p1stor${substring(suffix, 0, 12)}')

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

output storageAccountName string = sa.name
