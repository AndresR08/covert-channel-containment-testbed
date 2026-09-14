// main_nparty.bicep
// P1: n-party sweep over the S1 containment control (scoped SAS).
//
// Deploys N writer sandboxes plus 1 reader sandbox, each in its own container
// group with no shared VNet and no inbound exposure, all competing against the
// same storage account. Every party holds exactly one SAS bound to its own
// container; no party holds the account key.
//
// Resource groups are prefixed rg-p1- so this never touches the S1 groups.

targetScope = 'subscription'

param location string = 'eastus'
param suffix string = uniqueString(subscription().id, 'p1')

@description('Number of concurrent writers for this run.')
param writerCount int

@description('Per-run id; keeps each N sweep in its own namespaces.')
param runId string

param writerScriptB64 string
param readerScriptB64 string
param writesPerWriter int = 20
param containerImage string = 'mcr.microsoft.com/devcontainers/python:3.12'

param project string = 'apart-sprint-bogota'
param track string = 'containment-standards'
param eventDate string = '2026-09'

@description('Scenario tag, e.g. p1-nparty-n2.')
param environment string

var tags = {
  project: project
  track: track
  'event-date': eventDate
  environment: environment
  experiment: 'p1-nparty'
}

var storageRgName = 'rg-p1-storage'
var writersRgName = 'rg-p1-writers'
var readerRgName = 'rg-p1-reader'

resource storageRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: storageRgName
  location: location
  tags: tags
}

resource writersRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: writersRgName
  location: location
  tags: tags
}

resource readerRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: readerRgName
  location: location
  tags: tags
}

module storage 'storage_p1.bicep' = {
  name: 'p1-storage-deploy'
  scope: storageRg
  params: {
    location: location
    suffix: suffix
    tags: tags
  }
}

module sas 'containment_sas_nparty.bicep' = {
  name: 'p1-sas-deploy-${runId}'
  scope: storageRg
  params: {
    storageAccountName: storage.outputs.storageAccountName
    runId: runId
    writerCount: writerCount
  }
}

module writers 'sandbox_p1.bicep' = [for i in range(0, writerCount): {
  name: 'p1-writer-${runId}-${i}'
  scope: writersRg
  params: {
    location: location
    containerGroupName: 'p1-w${runId}-${i}'
    role: 'writer'
    scriptB64: writerScriptB64
    sasUrl: sas.outputs.writerSasUrls[i]
    blobContainerName: 'wr-${runId}-${i}'
    writerIndex: string(i)
    nWriters: writerCount
    writesPerWriter: writesPerWriter
    image: containerImage
    tags: tags
  }
}]

module reader 'sandbox_p1.bicep' = {
  name: 'p1-reader-${runId}'
  scope: readerRg
  params: {
    location: location
    containerGroupName: 'p1-r${runId}'
    role: 'reader'
    scriptB64: readerScriptB64
    sasUrl: sas.outputs.readerSasUrl
    blobContainerName: 'rd-${runId}'
    nWriters: writerCount
    image: containerImage
    tags: tags
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output runId string = runId
output writerCount int = writerCount
output writerContainerNames array = sas.outputs.writerContainerNames
output readerContainerName string = sas.outputs.readerContainerName
output blobEndpoint string = sas.outputs.blobEndpoint
