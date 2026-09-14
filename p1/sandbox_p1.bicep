// sandbox_p1.bicep
// One sandbox for the P1 n-party experiment. Same isolation properties as
// sandbox.bicep (S1): NO subnetId (no shared VNet, so no route between
// sandboxes) and NO ipAddress (no inbound exposure). Duplicated rather than
// modified so the S1 base files stay untouched.

param location string
param containerGroupName string
param role string
param scriptB64 string
param image string = 'mcr.microsoft.com/devcontainers/python:3.12'

@description('Container-scoped SAS URL. This sandbox receives no other credential.')
@secure()
param sasUrl string

param blobContainerName string
param writerIndex string = ''
param nWriters int = 0
param writesPerWriter int = 20
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
          environmentVariables: [
            {
              name: 'SCRIPT_B64'
              value: scriptB64
            }
            {
              name: 'BLOB_CONTAINER'
              value: blobContainerName
            }
            {
              name: 'WRITER_INDEX'
              value: writerIndex
            }
            {
              name: 'N_WRITERS'
              value: string(nWriters)
            }
            {
              name: 'WRITES_PER_WRITER'
              value: string(writesPerWriter)
            }
            {
              name: 'BLOB_SAS_URL'
              secureValue: sasUrl
            }
          ]
        }
      }
    ]
  }
}
