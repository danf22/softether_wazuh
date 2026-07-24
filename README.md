# Deploy SoftEther VPN + Wazuh + Suricata IDS on AWS with CloudFormation

This project deploys SoftEther VPN with Wazuh SIEM and Suricata IDS on Amazon Web Services using CloudFormation. It provides automated VPN provisioning with persistent configuration, intrusion detection on decrypted VPN traffic, malicious IP detection via AlienVault reputation lists, and pre-built monitoring dashboards — all through Infrastructure as Code.

## Templates

| Template | Description |
|---|---|
| `vpc.yml` | VPC with 2 public and 2 private subnets, NAT Gateway, and routing |
| `Softether_wazuh.yml` | SoftEther + Wazuh + Suricata (unified template with internal/external mode) |
| `Sofether_internal_no_wazuh.yml` | SoftEther only (no Wazuh/Suricata) with a public Elastic IP |

## Architecture

The unified `Softether_wazuh.yml` template supports two deployment modes:

- **Internal mode**: SoftEther gets a public Elastic IP (direct internet access)
- **External mode**: SoftEther sits behind a Network Load Balancer with TLS termination

Both modes share these characteristics:

- **Amazon Linux 2** AMI (auto-resolved via SSM parameter)
- **Nitro instance support** (t3a.medium default)
- **systemd service** for vpnserver with automatic config backup on start/stop
- **Persistent VPN configuration** on a dedicated encrypted EBS volume (`DeletionPolicy: Retain`)
- **Default VPN user** created during first deployment via parameters
- **IP forwarding** persisted via `/etc/sysctl.d/99-ip-forward.conf`
- **cfn-signal** for reliable CloudFormation creation feedback
- **Suricata IDS** on SoftEther instance inspecting decrypted VPN traffic
- **Wazuh agent** on SoftEther instance forwarding VPN security logs and Suricata alerts
- **Automatic dashboard import** — visualizations and dashboards are imported into Wazuh during deployment

### Security Monitoring Stack

| Component | Role |
|---|---|
| **SoftEther VPN** | VPN server with L2TP/IPsec |
| **Suricata IDS** | Network intrusion detection on decrypted VPN traffic |
| **Wazuh Manager** | SIEM: log collection, rule correlation, alerting |
| **Wazuh Agent** | Forwards SoftEther logs, traffic stats, and Suricata eve.json to the manager |
| **AlienVault OTX** | Threat intelligence IP reputation database |

### Suricata IDS Features

- Inspects decrypted VPN traffic (sees inside the tunnel)
- ET Open ruleset with daily automatic updates via `suricata-update`
- EVE JSON logging (alerts, DNS, TLS, HTTP, flows, anomalies)
- Custom Wazuh rules for VPN-specific IDS alerts (severity-based escalation)
- Detects: malware downloads, exploit attempts, port scanning, DNS tunneling, suspicious TLS certificates

### Wazuh Features

- AlienVault IP reputation database integration
- Custom decoders for SoftEther VPN log parsing
- Custom rules for authentication events, brute-force detection, and malicious IP alerts
- Traffic monitoring with high-bandwidth and unusual packet ratio detection
- Suricata alert correlation with VPN session data
- Three pre-configured dashboards:
  - **SoftEther VPN Dashboard** — OS, Country, City, VPN Map, AlienVault IPs, user auth table
  - **SoftEther VPN Traffic Monitoring** — bandwidth alerts, unusual patterns, top users
  - **Suricata IDS Dashboard** — alert severity, signatures, categories, DNS queries, TLS connections
- Active response capability for blocking malicious IPs

## Parameters

Parameters are organized into groups in the CloudFormation console:

### Deployment Configuration

| Parameter | Description | Default |
|---|---|---|
| `DeploymentMode` | `internal` (EIP) or `external` (NLB + TLS) | `internal` |
| `EC2InstanceType` | Instance type for SoftEther and Wazuh | `t3a.medium` |
| `LatestAmiId` | SSM path for Amazon Linux 2 AMI | `/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-ebs` |
| `AvailabilityZone` | AZ for deployment (must match subnets) | — |

### Network Configuration

| Parameter | Description | Default |
|---|---|---|
| `VPCId` | VPC ID for deployment | — |
| `SubnetIdSoftether` | Public subnet (internal) or private subnet (external) for SoftEther | — |
| `SubnetIdPrivateWazuh` | Private subnet for Wazuh | — |
| `SubnetIdPublicOne` | First public subnet for NLB (external only) | `''` |
| `SubnetIdPublicTwo` | Second public subnet for NLB (external only) | `''` |
| `CertificateArn` | ACM certificate ARN for TLS (external only) | `''` |

### SoftEther VPN Configuration

| Parameter | Description | Default |
|---|---|---|
| `NameBurtualHubVPN` | SoftEther Virtual Hub name | — |
| `SoftetherPassword` | SoftEther server admin password | — |
| `IPsecPreSharedKey` | IPsec L2TP pre-shared key | — |
| `DefaultVPNUser` | Default VPN username | — |
| `DefaultVPNUserPassword` | Password for the default VPN user | — |
| `SoftetherDownloadUrl` | Full URL for SoftEther tarball | v4.44-9807-rtm |

### Wazuh Configuration

| Parameter | Description | Default |
|---|---|---|
| `WazuhPassword` | Wazuh admin password | — |
| `WazuhVersion` | Wazuh version to deploy | `4.14` |

## Infrastructure Resources

The CloudFormation templates create the following AWS resources:

- VPC with public/private subnets and NAT Gateway (`vpc.yml`)
- EC2 instances (SoftEther with Suricata, and Wazuh)
- Security Groups (VPN ports 443/TCP, 500/UDP, 4500/UDP, 1701/UDP)
- IAM Roles with SSM access for management
- Network Interfaces
- Dedicated encrypted EBS volumes for config persistence
- Elastic IP (internal mode) or Network Load Balancer (external mode)

## Deployment

### Step 1: Deploy the VPC

Deploy `vpc.yml`. It creates a VPC with 2 public subnets, 2 private subnets, a NAT Gateway, and routing tables.

**Important:** All subnets used for SoftEther and Wazuh must be in the **same AZ** as the `AvailabilityZone` parameter you choose.

### Step 2: Deploy SoftEther + Wazuh + Suricata

#### Option A: Internal Mode (Elastic IP)

Best for: direct internet access without a load balancer.

```bash
./deploy.sh
# Select option 1
```

Provide: VPC ID, public subnet (SoftEther), private subnet (Wazuh), AZ, passwords, hub name, PSK, and default VPN user credentials.

Outputs: Wazuh URL, SoftEther Elastic IP.

![SoftEther + Wazuh architecture](Softether+Wazuh.png)

#### Option B: External Mode (NLB + TLS)

Best for: production deployments with TLS termination and a custom domain.

**Requires:** A domain name and an ACM certificate.

```bash
./deploy.sh
# Select option 3
```

Provide: ACM certificate ARN, VPC ID, private subnets (SoftEther + Wazuh), two public subnets (NLB), AZ, passwords, hub name, PSK, and default VPN user credentials.

Add the NLB DNS name as a CNAME on your domain.

Outputs: Wazuh URL, NLB DNS name.

![SoftEther + Wazuh + NLB architecture](Softether+Wazuh+NLB.png)

#### Option C: SoftEther Only (No Wazuh/Suricata)

Best for: VPN-only deployments without monitoring.

```bash
./deploy.sh
# Select option 2
```

Uses `Sofether_internal_no_wazuh.yml`. Outputs: SoftEther Elastic IP.

### Step 3: Connect to SoftEther VPN

Use the **SoftEther VPN Client** or any L2TP/IPsec client. Connect using:
- Server: Elastic IP (internal mode) or domain name (external mode)
- Hub: the hub name you specified
- User: the default VPN user credentials from the stack parameters
- IPsec PSK: the pre-shared key you specified

You can also use the **SoftEther VPN Server Manager** to manage hubs, users, and settings.

### Step 4: Access Wazuh

Once connected to the VPN, access the Wazuh interface at the URL shown in the stack Outputs. Log in with user `admin` and the Wazuh password from stack parameters.

Three dashboards are automatically imported and available under **Dashboards** in the Wazuh UI:
- **SoftEther VPN Dashboard** — connection overview with geo maps
- **SoftEther VPN Traffic Monitoring** — bandwidth and anomaly alerts
- **Suricata IDS Dashboard** — intrusion detection alerts and network analysis

### Step 5: Active Response Configuration (Optional)

To enable active response (automatic IP blocking) on the Wazuh instance:

1. Connect via AWS Session Manager: `sudo su`
2. Edit `/var/ossec/etc/ossec.conf` and add:
    ```xml
    <ossec_config>
      <active-response>
        <disabled>no</disabled>
        <command>netsh</command>
        <location>local</location>
        <rules_id>100100</rules_id>
        <timeout>60</timeout>
      </active-response>
    </ossec_config>
    ```
3. Restart: `sudo systemctl restart wazuh-manager`

## EBS Config Volume

The dedicated EBS volume ensures VPN configuration survives instance replacement:

1. **First boot:** volume is formatted, VPN is configured from parameters, default user is created, config is backed up.
2. **Systemd service:** syncs config to EBS on every start/stop.
3. **Subsequent boots:** existing config is detected and restored — VPN setup commands are skipped entirely.

The volume uses `DeletionPolicy: Retain` so it survives stack deletes.

## Suricata IDS

Suricata is installed on the SoftEther instance to inspect **decrypted** VPN traffic. This gives visibility into what VPN users are actually doing on the network.

### What it detects:
- Malware downloads and C2 communication
- Exploit attempts (CVE-based signatures)
- Port scanning and reconnaissance
- DNS tunneling and DGA domains
- Suspicious TLS certificates
- Protocol anomalies

### Configuration:
- Custom config at `/etc/suricata/suricata-softether.yaml`
- HOME_NET: `192.168.30.0/24` (VPN DHCP range) + `10.0.0.0/16` (VPC)
- Rules updated daily via cron (`suricata-update`)
- EVE JSON output forwarded to Wazuh agent
- Logs at `/var/log/suricata/eve.json`

### Wazuh Rules for Suricata:
| Rule ID | Level | Description |
|---|---|---|
| 100950 | 6 | Low-severity IDS alert from VPN client |
| 100951 | 10 | Medium-severity IDS alert from VPN client |
| 100952 | 13 | High-severity IDS alert from VPN client |
| 100953 | 14 | 10+ alerts from same VPN client in 5 minutes |
| 100954 | 12 | DNS query to suspicious domain from VPN client |
| 100955 | 8 | TLS connection logging from VPN clients |

## Visualizations and Dashboards

The `Visualizations.ndjson` file contains pre-configured Wazuh saved objects:

### SoftEther VPN Dashboard

| Object | Type | Description |
|---|---|---|
| OS System | Pie chart | Operating systems connecting to the VPN |
| Country | Pie chart | Countries of connecting clients |
| City | Pie chart | Cities of connecting clients |
| VPN Map | Tile map | Geographic map of VPN connection attempts |
| Table of IPs found in AlienVault | Table | IPs flagged in the AlienVault reputation database |
| User authentication successful table | Table | Successful VPN logins with IP, user, country, city, and time |

### SoftEther VPN Traffic Monitoring Dashboard

| Object | Type | Description |
|---|---|---|
| Traffic Alerts by Rule | Pie chart | Distribution of traffic alert types |
| Top Users by Traffic Alerts | Bar chart | Users generating the most traffic alerts |
| High Traffic Alerts Over Time | Histogram | Timeline of high-bandwidth alerts |
| Unusual Traffic Patterns | Histogram | Timeline of port scan / DDoS indicators |
| VPN Traffic Monitor - User Sessions | Table | Session details with user, IP, and alert type |

### Suricata IDS Dashboard

| Object | Type | Description |
|---|---|---|
| Suricata Alerts by Severity | Pie chart | Distribution of alerts by Wazuh rule level |
| Suricata Alert Categories | Pie chart | ET Open rule categories (Malware, Exploit, etc.) |
| Suricata Alerts Over Time | Histogram | Timeline of IDS alerts by category |
| Suricata Top Alert Signatures | Bar chart | Most triggered IDS signatures |
| Suricata Top Source IPs | Table | Source IP, destination, port, and signature |
| Suricata DNS Queries from VPN | Table | DNS queries by VPN clients |
| Suricata TLS Connections | Table | TLS connections with SNI, version, and certificate |

These are automatically imported during deployment. To manually re-import: **Dashboards Management → Saved Objects → Import** and select `Visualizations.ndjson`.

## Files

```
├── vpc.yml                         # VPC infrastructure
├── Softether_wazuh.yml             # SoftEther + Wazuh + Suricata (unified, internal/external)
├── Sofether_internal_no_wazuh.yml  # SoftEther only + Elastic IP
├── deploy.sh                       # Interactive deployment script
├── Visualizations.ndjson           # Wazuh dashboards and visualizations
├── Softether+Wazuh.png             # Architecture diagram (internal)
├── Softether+Wazuh+NLB.png         # Architecture diagram (external/NLB)
└── README.md
```

## Version History

| Version | Changes |
|---|---|
| v2.0 | Merged internal/external templates into unified `Softether_wazuh.yml` with deployment mode parameter. Added Suricata IDS integration. Added parameterized SoftEther and Wazuh versions. Added Suricata IDS Dashboard. Organized parameters with CloudFormation Interface metadata. |
| v1.0 | Initial release with separate internal/external templates. SoftEther + Wazuh with AlienVault threat intel and traffic monitoring. |
