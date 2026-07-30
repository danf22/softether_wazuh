# Deploy SoftEther VPN + Wazuh on AWS with CloudFormation

This project deploys SoftEther VPN with Wazuh SIEM on Amazon Web Services using CloudFormation. It provides automated VPN provisioning with persistent configuration, malicious IP detection via AlienVault reputation lists, automatic IP blocking via active response, and a pre-built monitoring dashboard — all through Infrastructure as Code.

## Templates

| Template | Description |
|---|---|
| `vpc.yml` | VPC with 2 public and 2 private subnets, NAT Gateway, and routing |
| `Softether_wazuh.yml` | SoftEther + Wazuh (unified template with internal/external mode) |
| `Sofether_internal_no_wazuh.yml` | SoftEther only (no Wazuh) with a public Elastic IP |

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
- **Wazuh agent** on SoftEther instance forwarding VPN security logs
- **Automatic dashboard import** — visualizations imported into Wazuh during deployment
- **Active response** — automatic IP blocking for AlienVault-flagged IPs

### Security Monitoring Stack

| Component | Role |
|---|---|
| **SoftEther VPN** | VPN server with L2TP/IPsec |
| **Wazuh Manager** | SIEM: log collection, rule correlation, alerting, active response |
| **Wazuh Agent** | Forwards SoftEther security logs to the manager |
| **AlienVault OTX** | Threat intelligence IP reputation database |

### Wazuh Features

- AlienVault IP reputation database integration
- Custom decoders for SoftEther VPN log parsing
- Custom rules for authentication events, brute-force detection, and malicious IP alerts
- **Active response**: automatically blocks IPs found in AlienVault reputation list via `firewall-drop` (iptables)
- Pre-configured dashboard:
  - **SoftEther VPN Dashboard** — OS, Country, City, VPN Map, AlienVault IPs, user auth table

### Active Response

When a VPN connection attempt comes from an IP found in the AlienVault reputation database, the system automatically:

1. Wazuh Manager triggers rule `100100` or `100305`
2. Active response executes `firewall-drop` on the SoftEther agent
3. An iptables DROP rule is added for the offending IP
4. The IP is automatically unblocked after 1 hour (configurable)

This is enabled by default during deployment — no manual configuration needed.

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
- IAM Roles with SSM access for management
- Network Interfaces
- Dedicated encrypted EBS volumes for config persistence
- Elastic IP (internal mode) or Network Load Balancer with ACM certificate (external mode)
- Route 53 DNS record (external mode)

## Deployment

### Step 1: Deploy the VPC

Deploy `vpc.yml`. It creates a VPC with 2 public subnets, 2 private subnets, a NAT Gateway, and routing tables.

**Important:** All subnets used for SoftEther and Wazuh must be in the **same AZ** as the `AvailabilityZone` parameter you choose.

### Step 2: Deploy SoftEther + Wazuh

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

**Requires:** A Route 53 hosted zone with your domain. The stack automatically creates the ACM certificate (with DNS validation) and the DNS A-record alias pointing to the NLB.

```bash
./deploy.sh
# Select option 3
```

Provide: VPC ID, private subnets (SoftEther + Wazuh), two public subnets (NLB), AZ, domain name, Route 53 hosted zone ID, passwords, hub name, PSK, and default VPN user credentials.

Outputs: Wazuh URL, NLB DNS name, VPN domain name.

![SoftEther + Wazuh + NLB architecture](Softether+Wazuh+NLB.png)

#### Option C: SoftEther Only (No Wazuh)

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

The **SoftEther VPN Dashboard** is automatically imported and available under **Dashboards** in the Wazuh UI.

## Active Response Details

Active response is configured automatically during deployment. When an IP from the AlienVault reputation database attempts to connect to the VPN:

- **Rules triggered**: `100100` (AlienVault IP in web/attack events) and `100305` (AlienVault IP attempting VPN login)
- **Action**: `firewall-drop` — adds an iptables INPUT/DROP rule on the SoftEther instance
- **Location**: `local` — executes on the agent where the event was detected
- **Timeout**: 3600 seconds (1 hour) — IP is automatically unblocked after timeout

To customize the timeout or add more rules, edit `/var/ossec/etc/ossec.conf` on the Wazuh manager:

```xml
<active-response>
  <disabled>no</disabled>
  <command>firewall-drop</command>
  <location>local</location>
  <rules_id>100100,100305</rules_id>
  <timeout>3600</timeout>
</active-response>
```

Set `<timeout>0</timeout>` for permanent blocks. Restart after changes: `sudo systemctl restart wazuh-manager`.

## EBS Config Volume

The dedicated EBS volume ensures VPN configuration survives instance replacement:

1. **First boot:** volume is formatted, VPN is configured from parameters, default user is created, config is backed up.
2. **Systemd service:** syncs config to EBS on every start/stop.
3. **Subsequent boots:** existing config is detected and restored — VPN setup commands are skipped entirely.

The volume uses `DeletionPolicy: Retain` so it survives stack deletes.

## Visualizations and Dashboard

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

These are automatically imported during deployment. To manually re-import: **Dashboards Management → Saved Objects → Import** and select `Visualizations.ndjson`.

## Custom Wazuh Rules

| Rule ID | Level | Description |
|---|---|---|
| 100100 | 10 | IP found in AlienVault reputation database (triggers active response) |
| 100302 | 0 | SoftEther authentication events (base rule, no alert) |
| 100303 | 3 | Remote connection attempt to VPN |
| 100304 | 5 | VPN user authentication failed |
| 100305 | 10 | AlienVault IP attempting VPN login (triggers active response) |
| 100306 | 10 | 10+ failed login attempts in 2 minutes (brute-force) |
| 100307 | 10 | 10+ connection attempts from same IP in 2 minutes |
| 100402 | 0 | SoftEther access events (base rule, no alert) |
| 100404 | 3 | Successful VPN user authentication |
| 100802 | 0 | SoftEther client details (base rule, no alert) |
| 100804 | 3 | Client details: OS, hostname |

## Files

```
├── vpc.yml                         # VPC infrastructure
├── Softether_wazuh.yml             # SoftEther + Wazuh (unified, internal/external)
├── Sofether_internal_no_wazuh.yml  # SoftEther only + Elastic IP
├── deploy.sh                       # Interactive deployment script
├── Visualizations.ndjson           # Wazuh dashboard and visualizations
├── Softether+Wazuh.png             # Architecture diagram (internal)
├── Softether+Wazuh+NLB.png         # Architecture diagram (external/NLB)
└── README.md
```

## Version History

| Version | Changes |
|---|---|
| v2.0 | Merged internal/external templates into unified `Softether_wazuh.yml`. Added deployment mode parameter. Route 53 + ACM automation for external mode. Parameterized SoftEther and Wazuh versions. Active response for automatic IP blocking. Organized parameters with CloudFormation Interface metadata. |
| v1.0 | Initial release with separate internal/external templates. SoftEther + Wazuh with AlienVault threat intel. |
