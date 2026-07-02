// Generates CA, server, and client certificates using a deployment script
// Uploads all certs to Key Vault as secrets (PEM format)

@description('Azure region')
param location string

@description('Key Vault name to store certificates')
param keyVaultName string

@description('Kafka VM private IP (for server cert SAN)')
param kafkaVmIp string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Managed identity for deployment script to write to Key Vault
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'cert-generator-identity'
  location: location
}

// Key Vault Secrets Officer role for the deployment script identity
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, scriptIdentity.id, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer
    principalId: scriptIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource certScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'generate-mtls-certs'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  dependsOn: [kvRoleAssignment]
  properties: {
    azCliVersion: '2.60.0'
    retentionInterval: 'PT1H'
    timeout: 'PT10M'
    scriptContent: '''
      #!/bin/bash
      set -e

      KV_NAME="${KEY_VAULT_NAME}"
      KAFKA_IP="${KAFKA_VM_IP}"
      CERT_DIR="/tmp/certs"
      mkdir -p $CERT_DIR

      # Generate CA key and certificate (4096-bit, 10-year validity)
      openssl genrsa -out $CERT_DIR/ca-key.pem 4096
      openssl req -new -x509 -key $CERT_DIR/ca-key.pem -sha256 \
        -subj "/CN=Kafka mTLS CA/O=Dev" \
        -days 3650 -out $CERT_DIR/ca-cert.pem

      # Generate server key and certificate (2048-bit, SAN with VM IP)
      openssl genrsa -out $CERT_DIR/server-key.pem 2048
      openssl req -new -key $CERT_DIR/server-key.pem \
        -subj "/CN=kafka-server/O=Dev" \
        -out $CERT_DIR/server.csr

      cat > $CERT_DIR/server-ext.cnf <<EOF
      [v3_req]
      subjectAltName = IP:${KAFKA_IP},DNS:kafka,DNS:localhost
      EOF

      openssl x509 -req -in $CERT_DIR/server.csr \
        -CA $CERT_DIR/ca-cert.pem -CAkey $CERT_DIR/ca-key.pem -CAcreateserial \
        -days 365 -sha256 -extfile $CERT_DIR/server-ext.cnf -extensions v3_req \
        -out $CERT_DIR/server-cert.pem

      # Generate client key and certificate (2048-bit)
      openssl genrsa -out $CERT_DIR/client-key.pem 2048
      openssl req -new -key $CERT_DIR/client-key.pem \
        -subj "/CN=kafka-client/O=Dev" \
        -out $CERT_DIR/client.csr

      openssl x509 -req -in $CERT_DIR/client.csr \
        -CA $CERT_DIR/ca-cert.pem -CAkey $CERT_DIR/ca-key.pem -CAcreateserial \
        -days 365 -sha256 \
        -out $CERT_DIR/client-cert.pem

      # Upload to Key Vault as secrets (PEM format)
      az keyvault secret set --vault-name "$KV_NAME" --name "ca-cert" --file $CERT_DIR/ca-cert.pem
      az keyvault secret set --vault-name "$KV_NAME" --name "ca-key" --file $CERT_DIR/ca-key.pem
      az keyvault secret set --vault-name "$KV_NAME" --name "server-cert" --file $CERT_DIR/server-cert.pem
      az keyvault secret set --vault-name "$KV_NAME" --name "server-key" --file $CERT_DIR/server-key.pem
      az keyvault secret set --vault-name "$KV_NAME" --name "client-cert" --file $CERT_DIR/client-cert.pem
      az keyvault secret set --vault-name "$KV_NAME" --name "client-key" --file $CERT_DIR/client-key.pem

      echo "All certificates generated and uploaded to Key Vault: $KV_NAME"
    '''
    environmentVariables: [
      { name: 'KEY_VAULT_NAME', value: keyVaultName }
      { name: 'KAFKA_VM_IP', value: kafkaVmIp }
    ]
  }
}

output scriptName string = certScript.name
