// containment_sas_nparty.bicep
// P1: the S1 containment control (variant b) generalized from 2 parties to N.
//
// Same primitive as containment_sas.bicep: each party receives a service SAS
// whose signature is cryptographically bound to the canonicalized path of its
// OWN container, with a minimal permission set. Nothing here manages contention
// between parties; the boundary is per-credential path binding, which is the
// property P1 is testing as N grows.
//
//   writer i  ->  container wr-<runId>-<i>, permission cw (create + write only)
//   reader    ->  container rd-<runId>,     permission rl (read + list only)
//
// No party receives the storage account key.

param storageAccountName string
param runId string
param writerCount int

@description('Short-lived window; must outlast ACI cold start plus the write batch.')
param sasExpiry string = dateTimeAdd(utcNow(), 'PT45M')

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: sa
  name: 'default'
}

// One container per writer. Disjoint namespaces by construction.
resource writerContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for i in range(0, writerCount): {
  parent: blobService
  name: 'wr-${runId}-${i}'
  properties: {
    publicAccess: 'None'
  }
}]

resource readerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'rd-${runId}'
  properties: {
    publicAccess: 'None'
  }
}

var blobEndpoint = 'https://${sa.name}.blob.${environment().suffixes.storage}'

// N writer SAS, each signed over its own container path only, minted one per
// module invocation (Bicep forbids list*() in a loop-variable body).
module writerSas 'sas_one.bicep' = [for i in range(0, writerCount): {
  name: 'p1-sas-w-${runId}-${i}'
  params: {
    storageAccountName: sa.name
    containerName: 'wr-${runId}-${i}'
    permission: 'cw'
    sasExpiry: sasExpiry
  }
  dependsOn: [
    writerContainers
  ]
}]

module readerSas 'sas_one.bicep' = {
  name: 'p1-sas-r-${runId}'
  params: {
    storageAccountName: sa.name
    containerName: 'rd-${runId}'
    permission: 'rl'
    sasExpiry: sasExpiry
  }
  dependsOn: [
    readerContainer
  ]
}

output writerSasUrls array = [for i in range(0, writerCount): writerSas[i].outputs.sasUrl]
output readerSasUrl string = readerSas.outputs.sasUrl
output writerContainerNames array = [for i in range(0, writerCount): 'wr-${runId}-${i}']
output readerContainerName string = 'rd-${runId}'
output sasExpiry string = sasExpiry
output blobEndpoint string = blobEndpoint
