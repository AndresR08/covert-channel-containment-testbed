// main.bicep
// Subscription-scoped deployment for the covert-channel verification testbed.
//
// Provisions THREE administratively separate resource groups:
//   rg-cc-storage     -> the shared mutable resource (1 Storage Account + 1 blob container)
//   rg-cc-sandbox-a   -> Container A (writer)
//   rg-cc-sandbox-b   -> Container B (reader)
//
// ISOLATION MODEL: neither container group is placed in a VNet (no subnetIds).
// They therefore have NO network route to each other. Each only reaches the
// storage account over its public endpoint. Separate resource groups are for
// administrative separation only -- the "no direct path" property comes from
// the absence of any shared VNet.
//
// Deploy with: az deployment sub create ... (see deploy.sh)

targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Short suffix to keep global names unique. Stable per subscription so re-runs reuse the same storage account instead of spawning a new one each deploy.')
param suffix string = uniqueString(subscription().id)

@description('Base64-encoded writer.py. deploy.sh fills this in automatically.')
param writerScriptB64 string

@description('Base64-encoded reader.py. deploy.sh fills this in automatically.')
param readerScriptB64 string

@description('Blob container used as the shared mutable resource.')
param blobContainerName string = 'covert-channel'

@description('Base image for both sandboxes. Override with an MCR-hosted image to avoid Docker Hub rate limits from ACI.')
param containerImage string = 'python:3.12-slim'

@description('Containment control. "none" = the "before" behavior (shared container + account key). "scoped-sas" = variant (b): per-sandbox least-privilege short-lived SAS, no account key handed to sandboxes.')
@allowed([
  'none'
  'scoped-sas'
])
param containmentMode string = 'none'

@description('Per-run id for the scoped-sas containers. Unique per deployment so each run gets its own disjoint namespaces.')
param runId string = uniqueString(deployment().name)

// --- Cost-traceability tags (Apart Research Sprint accounting) ---------------
@description('Project tag applied to every resource.')
param project string = 'apart-sprint-bogota'

@description('Track tag applied to every resource.')
param track string = 'containment-standards'

@description('Event-date tag (YYYY-MM) applied to every resource.')
param eventDate string = '2026-09'

@description('Scenario tag: distinguishes cost of each run, e.g. before-control | after-control. Change this per run to filter spend separately in Cost Management.')
param environment string

// One tags object, built from the params above and reused across all three
// resource groups AND passed into every module so individual resources
// (storage account, container groups) carry the same tags. Change only
// `environment` between runs.
var tags = {
  project: project
  track: track
  'event-date': eventDate
  environment: environment
}

var storageRgName  = 'rg-cc-storage'
var sandboxARgName = 'rg-cc-sandbox-a'
var sandboxBRgName = 'rg-cc-sandbox-b'

resource storageRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: storageRgName
  location: location
  tags: tags
}

resource sandboxARg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: sandboxARgName
  location: location
  tags: tags
}

resource sandboxBRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: sandboxBRgName
  location: location
  tags: tags
}

module storage 'storage.bicep' = {
  name: 'storage-deploy'
  scope: storageRg
  params: {
    location: location
    suffix: suffix
    blobContainerName: blobContainerName
    tags: tags
  }
}

// Containment variant (b): mint per-sandbox scoped SAS + disjoint containers.
// Deployed ONLY when containmentMode == 'scoped-sas'. Base infra untouched.
module sas 'containment_sas.bicep' = if (containmentMode == 'scoped-sas') {
  name: 'containment-sas-deploy'
  scope: storageRg
  params: {
    storageAccountName: storage.outputs.storageAccountName
    runId: runId
  }
}

// Credential/namespace wiring. In 'none' mode both sandboxes get the account key
// and the shared container (before). In 'scoped-sas' mode each gets ONLY its own
// SAS URL + its own container, and no account key.
var useScopedSas    = containmentMode == 'scoped-sas'
var writerContainer = useScopedSas ? sas.outputs.writerContainerName : blobContainerName
var readerContainer = useScopedSas ? sas.outputs.readerContainerName : blobContainerName
var writerSasUrl    = useScopedSas ? sas.outputs.writerSasUrl : ''
var readerSasUrl    = useScopedSas ? sas.outputs.readerSasUrl : ''
var writerConn      = useScopedSas ? '' : storage.outputs.connectionString
var readerConn      = useScopedSas ? '' : storage.outputs.connectionString

module sandboxA 'sandbox.bicep' = {
  name: 'sandbox-a-deploy'
  scope: sandboxARg
  params: {
    location: location
    containerGroupName: 'sandbox-a'
    role: 'writer'
    scriptB64: writerScriptB64
    storageConnectionString: writerConn
    sasUrl: writerSasUrl
    blobContainerName: writerContainer
    image: containerImage
    tags: tags
  }
}

module sandboxB 'sandbox.bicep' = {
  name: 'sandbox-b-deploy'
  scope: sandboxBRg
  params: {
    location: location
    containerGroupName: 'sandbox-b'
    role: 'reader'
    scriptB64: readerScriptB64
    storageConnectionString: readerConn
    sasUrl: readerSasUrl
    blobContainerName: readerContainer
    image: containerImage
    tags: tags
  }
}

output storageAccountName string = storage.outputs.storageAccountName
output blobContainerName string = blobContainerName
output containmentMode string = containmentMode
output writerContainer string = writerContainer
output readerContainer string = readerContainer
