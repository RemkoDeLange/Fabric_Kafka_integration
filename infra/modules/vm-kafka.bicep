// Kafka VM module: Ubuntu 22.04 VM with Docker + Docker Compose via cloud-init
// Single-node Kafka (KRaft) + Kafka Connect will run as Docker containers

@description('Azure region')
param location string

@description('Base name prefix for resources')
param namePrefix string

@description('Subnet ID for the VM NIC')
param subnetId string

@description('Admin username for SSH')
param adminUsername string = 'azureuser'

@description('SSH public key for authentication')
@secure()
param adminSshPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2ms'

// --- Cloud-init script: installs Docker + Docker Compose ---
var cloudInitScript = '''
#cloud-config
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release

runcmd:
  # Install Docker
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  # Add admin user to docker group
  - usermod -aG docker ${adminUsername}
  # Format and mount data disk
  - parted /dev/disk/azure/scsi1/lun0 --script mklabel gpt mkpart primary ext4 0% 100%
  - sleep 5
  - mkfs.ext4 /dev/disk/azure/scsi1/lun0-part1
  - mkdir -p /data/kafka
  - mount /dev/disk/azure/scsi1/lun0-part1 /data/kafka
  - echo "/dev/disk/azure/scsi1/lun0-part1 /data/kafka ext4 defaults,nofail 0 2" >> /etc/fstab
  - chown -R 1000:1000 /data/kafka
'''

// --- Public IP (temporary, for SSH access during dev) ---
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${namePrefix}-kafka-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// --- NIC ---
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${namePrefix}-kafka-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// --- VM ---
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: '${namePrefix}-kafka-vm'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 30
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 64
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    osProfile: {
      computerName: '${namePrefix}-kafka'
      adminUsername: adminUsername
      customData: base64(cloudInitScript)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// --- Outputs ---
output vmId string = vm.id
output vmName string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output vmPublicIp string = publicIp.properties.ipAddress
output adminUsername string = adminUsername
