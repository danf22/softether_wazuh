## Deploy Softether and Wazuh using CF on AWS

This project plans to deploy SoftEther VPN and Wazuh (an open-source security monitoring platform) using AWS CloudFormation (CF) to monitor and block malicious IPs.



## How Works

We will need a VPC with three minimum availability zones. This CF will be found in this repo.

The CF will install on the SoftEther instance and configure the WAZUH client to obtain the application's logs and send them to the central server.

WAZUH will receive the logs, and we will import a dashboard from the repo.