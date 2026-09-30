# GSP355 — Create and Manage Cloud SQL for PostgreSQL Instances

This repository contains a secret-free Cloud Shell helper for the Google Cloud Challenge Lab **GSP355**.

## Three-command Cloud Shell flow

```bash
curl -LO https://raw.githubusercontent.com/fakee62890-tech/gsp355-cloud-sql/master/lab.sh
sudo chmod +x lab.sh
./lab.sh
```

The script prompts for the temporary lab values at runtime. **Do not commit Qwiklabs passwords or student credentials to a public repository.**

## What the script automates

- Enables Database Migration, Service Networking, Cloud SQL Admin, and Compute Engine APIs.
- Detects the PostgreSQL source VM internal/external IP addresses.
- Installs and configures `postgresql-14-pglogical` on the source VM.
- Configures logical replication settings and restarts PostgreSQL.
- Creates or updates the migration user and grants migration read access.
- Creates or reuses a Database Migration Service PostgreSQL connection profile in `europe-west1`.
- Prints the exact remaining lab checks and values.

## Required console gates

GSP355's grader requires stateful operations that should be completed in the Cloud Console:

1. Create, test, start, and promote the continuous DMS migration job using VPC peering and the default VPC.
2. Add the source VM public IP to Cloud SQL authorized networks.
3. Add the Cloud IAM database user and grant `SELECT` on `orders.inventory_items`.
4. Enable backups and point-in-time recovery with **6 retained transaction-log days**.
5. Capture a UTC timestamp, insert the required row, and clone `postgres14-x5u2c` as `postgres-orders-pitr` at that timestamp.

The script does not claim to complete these GUI/grader gates automatically; it prints the values and commands needed to finish them safely.

## Time estimate

- Script execution and source preparation: typically **5–12 minutes**.
- DMS provisioning/migration and promotion: typically **10–25 minutes**, depending on lab backend load.
- IAM/PITR/PITR clone and progress checks: **5–10 minutes**.
- Practical total: **20–45 minutes**, with the lab timer and grader as the limiting factors.
