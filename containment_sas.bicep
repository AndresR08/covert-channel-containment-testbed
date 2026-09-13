// containment_sas.bicep
// CONTAINMENT CONTROL -- Variant (b): short-lived, least-privilege,
// per-sandbox scoped SAS.
//
// This module is ADDITIVE. The base infrastructure is untouched; main.bicep
// only invokes this module (and stops passing the account key to the sandboxes)
// when containmentMode == 'scoped-sas'.
//
// What it does:
//   - Creates TWO distinct per-run containers: wr-<runId> and rd-<runId>.
//   - Mints a WRITER SAS scoped to wr-<runId> with CREATE+WRITE only (no list/read).
//   - Mints a READER SAS scoped to rd-<runId> with READ+LIST only.
//   - Neither SAS is the account key; neither can reach the other's container.
//
// Why this closes the "before" channel:
//   In "before" both sandboxes held the account key (full reach over every
//   namespace). Here the reader's credential grants no access to the writer's
//   container -- an adversarial reader that targets wr-<runId> gets HTTP 403.
//   The channel is closed at the CREDENTIAL layer, not by naming convention.
//
// Honest scope note: Azure SAS is a bearer token valid until expiry -- it is
// NOT natively single-use. The "single-use" property is approximated by a short
// TTL + disjoint per-sandbox scope + minimal permissions. (No stored access
// policy / hard revocation in this build, to keep scope minimal for the sprint.)

@description('Name of the existing storage account (from storage.bicep output).')
param storageAccountName string

@description('Per-run id; makes the two containers unique per deployment.')
param runId string

@description('SAS expiry. Short-lived window; must outlast ACI cold start + run. Default 30 min. utcNow() is only valid as a param default.')
param sasExpiry string = dateTimeAdd(utcNow(), 'PT30M')

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: sa
  name: 'default'
}

// One container per sandbox -- they never share a namespace.
resource writerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'wr-${runId}'
  properties: {
    publicAccess: 'None'
  }
}

resource readerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'rd-${runId}'
  properties: {
    publicAccess: 'None'
  }
}

// WRITER SAS: create + write only, scoped to wr-<runId>. No list, no read ->
// the writer cannot itself be used as a receive channel.
var writerSas = sa.listServiceSas('2023-05-01', {
  canonicalizedResource: '/blob/${sa.name}/${writerContainer.name}'
  signedResource: 'c'
  signedPermission: 'cw'
  signedProtocol: 'https'
  signedExpiry: sasExpiry
}).serviceSasToken

// READER SAS: read + list only, scoped to a DIFFERENT container rd-<runId>.
var readerSas = sa.listServiceSas('2023-05-01', {
  canonicalizedResource: '/blob/${sa.name}/${readerContainer.name}'
  signedResource: 'c'
  signedPermission: 'rl'
  signedProtocol: 'https'
  signedExpiry: sasExpiry
}).serviceSasToken

var blobEndpoint = 'https://${sa.name}.blob.${environment().suffixes.storage}'

@description('Full container-scoped SAS URL for the writer sandbox.')
output writerSasUrl string = '${blobEndpoint}/${writerContainer.name}?${writerSas}'

@description('Full container-scoped SAS URL for the reader sandbox.')
output readerSasUrl string = '${blobEndpoint}/${readerContainer.name}?${readerSas}'

output writerContainerName string = writerContainer.name
output readerContainerName string = readerContainer.name
output sasExpiry string = sasExpiry
