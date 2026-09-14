// sandbox.bicep
// One Azure Container Instance running a benign Python script.
//
// Key isolation property: NO subnetIds and NO ipAddress block.
//   - No VNet  => no network route to the other sandbox.
//   - No public IP => no inbound exposure.
// The container still has outbound internet to reach the storage endpoint.
//
// The Python script is injected at runtime via a base64 env var so we don't
// have to build and push a custom image. The command decodes it, installs the
// SDK, and runs it.

@description('Region.')
param location string

@description('Name of the container group.')
param containerGroupName string

@description('Role label (writer|reader), used only for the container name and logs.')
param role string

@description('Base64-encoded Python script to execute.')
param scriptB64 string

@description('Base image. Default is Docker Hub python:3.12-slim; override with an MCR-hosted image (e.g. mcr.microsoft.com/devcontainers/python:3.12) to avoid Docker Hub anonymous pull rate limits from ACI shared egress IPs.')
param image string = 'python:3.12-slim'

@description('Storage connection string (account key): the shared resource both sandboxes reach. Used only when no scoped SAS is provided ("before" behavior). Optional so the SAS containment mode can withhold the account key entirely.')
@secure()
param storageConnectionString string = ''

@description('Container-scoped SAS URL (containment variant b). When set, the sandbox uses ONLY this least-privilege credential and the account key is never passed in.')
@secure()
param sasUrl string = ''

@description('Blob container name.')
param blobContainerName string

@description('Cost-traceability tags, passed from main.bicep.')
param tags object = {}

resource cg 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  tags: tags
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'
    containers: [
      {
        name: role
        properties: {
          image: image
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
          command: [
            '/bin/bash'
            '-c'
            'echo "$SCRIPT_B64" | base64 -d > /tmp/app.py && pip install --quiet --no-cache-dir azure-storage-blob && python /tmp/app.py'
          ]
          // Credential is EITHER the account key (before) OR a scoped SAS (variant b),
          // never both. When sasUrl is set, the account key is not passed in at all.
          environmentVariables: concat(
            [
              {
                name: 'SCRIPT_B64'
                value: scriptB64
              }
              {
                name: 'BLOB_CONTAINER'
                value: blobContainerName
              }
            ],
            empty(sasUrl) ? [
              {
                name: 'STORAGE_CONNECTION_STRING'
                secureValue: storageConnectionString
              }
            ] : [
              {
                name: 'BLOB_SAS_URL'
                secureValue: sasUrl
              }
            ]
          )
        }
      }
    ]
  }
}
