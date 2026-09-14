// sas_one.bicep
// Mints exactly one container-scoped service SAS.
//
// Exists because Bicep forbids list*() inside a loop-variable body (BCP182):
// loop bodies must be computable at the start of the deployment. Deploying this
// module N times is the supported way to mint N SAS. The primitive is identical
// to containment_sas.bicep (S1): the signature is bound to the canonicalized
// path of one container, with a minimal permission set.

param storageAccountName string
param containerName string

@description('SAS permission set, e.g. cw (create+write) or rl (read+list).')
param permission string

param sasExpiry string

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

var token = sa.listServiceSas('2023-05-01', {
  canonicalizedResource: '/blob/${sa.name}/${containerName}'
  signedResource: 'c'
  signedPermission: permission
  signedProtocol: 'https'
  signedExpiry: sasExpiry
}).serviceSasToken

output sasUrl string = 'https://${sa.name}.blob.${environment().suffixes.storage}/${containerName}?${token}'
