# Deploy SoftEther VPN + Wazuh on AWS with CloudFormation

This project deploys SoftEther VPN with Wazuh SIEM on Amazon Web Services using CloudFormation. It provides automated VPN provisioning with persistent configuration, malicious IP detection and blocking via AlienVault reputation lists, VPC Flow Logs monitoring, real-time traffic anomaly detection, and pre-built dashboards — all through Infrastructure as Code.

## Templates

| Template | Description |
|---|---|
| `vpc.yml` | VPC with 2 public and 2 private subnets, NAT Gateway, and routing |
| `Softether_wazuh.yml` | SoftEther + Wazuh (unified template with internal/external mode) |

## Architecture

The unified `Softether_wazuh.yml` template supports two deployment modes:

- **Internal mode**: SoftEther gets a public Elastic IP (direct internet access)
- **External mode**: SoftEther sits behind a Network Load Balancer with TLS termination

Both modes include:

- **Amazon Linux 2** AMI (auto-resolved via SSM parameter)
- **Nitro instance support** (t3a.medium default)
- **systemd service** for vpnserver with automatic config backup
- **Persistent VPN configuration** on a dedicated encrypted EBS volume (`DeletionPolicy: Retain`)
- **Persistent Wazuh configuration** on a separate encrypted EBS volume (`DeletionPolicy: Retain`)
- **Default VPN user** created during first deployment
- **IP forwarding** persisted via `/etc/sysctl.d/99-ip-forward.conf`
- **cfn-signal** for reliable CloudFormation creation feedback
- **Wazuh agent** on SoftEther instance forwarding VPN security logs
- **VPC Flow Logs** captured to S3 and ingested by Wazuh
- **Active response** — automatic IP blocking for AlienVault-flagged IPs
- **Daily AlienVault threat intel updates** via cron
- **Real-time traffic monitoring** — per-session bandwidth and packet analysis every 5 minutes
- **Pre-built dashboards** auto-imported during deployment

### Security Monitoring Stack

| Component | Role |
|---|---|
| **SoftEther VPN** | VPN server with L2TP/IPsec |
| **Wazuh Manager** | SIEM: log collection, rule correlation, alerting, active response |
| **Wazuh Agent** | Forwards SoftEther security and traffic logs to the manager |
| **AlienVault OTX** | Threat intelligence IP reputation database (auto-updated daily) |
| **VPC Flow Logs** | Network traffic metadata (accept/reject) for all VPC traffic |
| **Traffic Monitor** | Cron-based per-session bandwidth/packet analysis with anomaly alerts |

### Wazuh Features

- AlienVault IP reputation database integration (daily auto-update)
- Custom decoders for SoftEther VPN log parsing
- Custom rules for authentication events, brute-force detection, and malicious IP alerts
- **Active response**: automatically blocks IPs found in AlienVault via `firewall-drop` (iptables)
- **VPC Flow Logs**: ingested via S3 with accept/reject traffic analysis
- **Traffic monitoring**: per-session bandwidth tracking with high-traffic and unusual packet ratio alerts
- Pre-configured dashboards:
  - **SoftEther VPN Dashboard** — OS, Country, City, VPN Map, AlienVault IPs, user auth table
  - **VPC Flow Logs Dashboard** — Accepted vs Rejected, top rejected IPs, targeted ports, timeline

### Traffic Monitoring

A cron job runs every 5 minutes on the SoftEther instance to collect per-session traffic metrics:

- **Bytes transferred** (TX/RX totals and deltas since last check)
- **Packet counts** (unicast TX/RX)
- **Connection duration** (connected-since timestamp)

Alerts are generated for:

| Alert | Threshold | Description |
|---|---|---|
| HIGH_TRAFFIC | >100 MB in 5 min | Single session transferred over 100 MB delta |
| UNUSUAL_PACKET_RATIO | TX/RX ratio > 50:1 | Possible port scanning or DDoS behavior |

Wazuh rules escalate repeated anomalies:

| Rule ID | Level | Description |
|---|---|---|
| 100900 | 0 | Traffic monitoring event (no alert) |
| 100901 | 10 | High traffic detected (>100 MB in 5 min) |
| 100902 | 12 | Unusual packet ratio (possible scanning/DDoS) |
| 100903 | 13 | Sustained high traffic (3 alerts in 30 min — possible exfiltration) |
| 100904 | 14 | Repeated unusual pattern (3 alerts in 15 min — active attack) |

### Active Response

When a VPN connection attempt comes from an IP found in the AlienVault reputation database:

1. Wazuh Manager triggers rule `100100` or `100305`
2. Active response executes `firewall-drop` on the SoftEther agent
3. An iptables DROP rule is added for the offending IP
4. The IP is automatically unblocked after 1 hour (configurable)

Enabled by default — no manual configuration needed.

### VPC Flow Logs

All VPC network traffic is captured and analyzed:

1. AWS VPC Flow Logs deliver to an S3 bucket (60-second aggregation)
2. Wazuh's `aws-s3` module polls the bucket every 5 minutes
3. Flow events are indexed and available in the VPC Flow Logs Dashboard
4. Bucket has a 30-day lifecycle policy for automatic cleanup

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
| `DomainName` | VPN domain name, e.g. vpn.example.com (external only) | `''` |
| `HostedZoneId` | Route 53 Hosted Zone ID for the domain (external only) | `''` |

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
- EC2 instances (SoftEther and Wazuh)
- Security Groups (VPN ports 443/TCP, 500/UDP, 4500/UDP, 1701/UDP)
- IAM Roles with SSM + S3 + EC2 DescribeFlowLogs access
- Network Interfaces
- Dedicated encrypted EBS volumes for config persistence (SoftEther 5 GB, Wazuh 10 GB)
- S3 bucket for VPC Flow Logs (30-day retention)
- VPC Flow Log (all traffic, 60-second intervals)
- Elastic IP (internal mode) or Network Load Balancer with ACM certificate (external mode)
- Route 53 DNS record (external mode)
- ACM certificate with DNS validation (external mode)

## Deployment

### Prerequisites

- AWS CLI installed and configured
- Valid AWS credentials with permissions for CloudFormation, EC2, IAM, S3, ELB, ACM, and Route 53
- A Route 53 hosted zone (external mode only)

### Step 1: Run the deployment script

```bash
chmod +x deploy.sh
./deploy.sh
```

The script presents an interactive menu:

```
╔═══════════════════════════════════════════════════════════╗
║       SoftEther VPN + Wazuh — AWS Deployment Tool        ║
╚═══════════════════════════════════════════════════════════╝

  Deployment options:

    1) Internal — SoftEther + Wazuh (Elastic IP, direct access)
    2) Internal — SoftEther Only (Elastic IP, no monitoring)
    3) External — SoftEther + Wazuh (NLB + TLS + Route 53)

  Management:

    4) Destroy all stacks
    5) Exit
```

### Step 2: Choose VPC

The script asks whether to create a new VPC or use an existing one:
- **New VPC**: deploys `vpc.yml` automatically
- **Existing VPC**: prompts for VPC ID and subnet IDs

### Step 3: Configure parameters

The script prompts for all required values: region, AZ, hub name, passwords, instance type, and Wazuh version.

Password requirements: 8–64 characters with at least one uppercase, one lowercase, one number, and one special character (`. * + ? -`).

### Step 4: Connect to SoftEther VPN

Use the **SoftEther VPN Client** or any L2TP/IPsec client:
- Server: Elastic IP (internal) or domain name (external)
- Hub: the hub name you specified
- User/Password: default VPN credentials from parameters
- IPsec PSK: the pre-shared key you specified

### Step 5: Access Wazuh

Connect to the VPN, then access the Wazuh dashboard at the private IP shown in stack Outputs. Login: `admin` / your Wazuh password.

Two dashboards are available:
- **SoftEther VPN Dashboard** — VPN connection monitoring
- **VPC Flow Logs Dashboard** — network traffic analysis

### Destroy stacks

Option 4 in the deploy script removes all stacks. The S3 bucket is emptied automatically before deletion. EBS config volumes are retained (DeletionPolicy: Retain) so VPN and Wazuh configurations survive stack recreation.

## Active Response Configuration

Active response is configured automatically. To customize:

```xml
<active-response>
  <disabled>no</disabled>
  <command>firewall-drop</command>
  <location>local</location>
  <rules_id>100100,100305</rules_id>
  <timeout>3600</timeout>
</active-response>
```

- Set `<timeout>0</timeout>` for permanent blocks
- Add more rule IDs to expand blocking triggers
- Edit on Wazuh manager at `/var/ossec/etc/ossec.conf`, then restart: `sudo systemctl restart wazuh-manager`

## EBS Config Volumes

Dedicated EBS volumes ensure configuration survives instance replacement:

### SoftEther (5 GB, `/dev/xvdf`)

1. **First boot**: volume is formatted, VPN configured, default user created, config backed up
2. **Subsequent boots**: existing config detected and restored automatically
3. **DeletionPolicy: Retain**: volume survives stack deletes

### Wazuh (10 GB, `/dev/xvdg`)

1. **First boot**: Wazuh installed, rules/decoders/lists configured, everything backed up
2. **Subsequent boots**: config, rules, decoders, and lists restored from volume
3. **DeletionPolicy: Retain**: volume survives stack deletes

## Dashboards

### SoftEther VPN Dashboard

| Visualization | Type | Description |
|---|---|---|
| OS System | Pie chart | Operating systems connecting to the VPN |
| Country | Pie chart | Countries of connecting clients |
| City | Pie chart | Cities of connecting clients |
| VPN Map | Tile map | Geographic map of connection attempts |
| AlienVault IPs | Table | IPs flagged in reputation database |
| User Auth Table | Table | Successful logins with IP, user, country, city, time |

### VPC Flow Logs Dashboard

| Visualization | Type | Description |
|---|---|---|
| Accepted vs Rejected | Pie chart | Ratio of allowed vs blocked traffic |
| Top Rejected Source IPs | Bar chart | IPs generating the most rejected connections |
| Top Targeted Ports | Pie chart | Most targeted ports by blocked traffic |
| Events Over Time | Histogram | Timeline of flow events by action |
| Rejected Connections Detail | Table | Source IP, dest IP, port, protocol |

Dashboards are auto-imported during deployment. To manually re-import: **Dashboards Management → Saved Objects → Import** → select `Visualizations.ndjson`.

## Custom Wazuh Rules

| Rule ID | Level | Description |
|---|---|---|
| 100100 | 10 | IP found in AlienVault database (triggers block) |
| 100303 | 3 | Remote VPN connection attempt |
| 100304 | 5 | VPN authentication failed |
| 100305 | 10 | AlienVault IP attempting VPN login (triggers block) |
| 100306 | 10 | 10+ failed logins in 2 minutes (brute-force) |
| 100307 | 10 | 10+ connection attempts from same IP in 2 minutes |
| 100404 | 3 | Successful VPN authentication |
| 100804 | 3 | VPN client details (OS, hostname) |
| 100901 | 10 | High traffic alert (>100 MB in 5 min) |
| 100902 | 12 | Unusual packet ratio (possible scanning/DDoS) |
| 100903 | 13 | Sustained high traffic (possible data exfiltration) |
| 100904 | 14 | Repeated unusual traffic pattern (active attack) |

## Files

```
├── vpc.yml                    # VPC infrastructure (2 public + 2 private subnets, NAT)
├── Softether_wazuh.yml        # SoftEther + Wazuh (unified, internal/external mode)
├── deploy.sh                  # Interactive deployment script
├── Visualizations.ndjson      # Wazuh dashboards and visualizations
├── Softether+Wazuh.png        # Architecture diagram (internal mode)
├── Softether+Wazuh+NLB.png   # Architecture diagram (external/NLB mode)
└── README.md
```

## Version History

| Version | Changes |
|---|---|
| v3.0 | Added real-time traffic monitoring (per-session bandwidth/packet analysis). New Wazuh rules 100900–100904 for traffic anomaly detection. Wazuh persistent EBS volume with auto-restore. Dashboard auto-import during deployment. Removed standalone SoftEther-only template in favor of unified template. |
| v2.1 | Added VPC Flow Logs (S3 → Wazuh) with dashboard. Daily AlienVault auto-update cron. Deploy script VPC selection (new or existing). |
| v2.0 | Merged internal/external templates. Route 53 + ACM automation. Parameterized versions. Active response. CloudFormation Interface metadata. |
| v1.0 | Initial release with separate templates. SoftEther + Wazuh with AlienVault threat intel. |
