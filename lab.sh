#!/usr/bin/env bash
set -Eeuo pipefail

# GSP355 - Create and Manage Cloud SQL for PostgreSQL Instances
# Secret-free QuickLab script. It reads temporary lab values interactively.
# It is safe to re-run: existing resources are reused where possible.

log(){ printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\n\033[1;33mWARNING:\033[0m %s\n' "$*"; }
fail(){ printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v gcloud >/dev/null || fail "gcloud is not installed. Run this in Google Cloud Shell."
PROJECT_ID="${DEVSHELL_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || fail "No active Google Cloud project. Set it with: gcloud config set project PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

printf '\n\033[1;35mGSP355 Cloud SQL for PostgreSQL Challenge Lab\033[0m\n'
printf 'Active project: %s\n' "$PROJECT_ID"
printf 'Do not paste Qwiklabs passwords into GitHub; this script only uses them at runtime.\n\n'

read -r -p 'Postgres source VM name [postgresql-vm]: ' SOURCE_VM
SOURCE_VM="${SOURCE_VM:-postgresql-vm}"
read -r -p 'Source VM zone [europe-west1-d]: ' SOURCE_ZONE
SOURCE_ZONE="${SOURCE_ZONE:-europe-west1-d}"
read -r -p 'DMS region [europe-west1]: ' REGION
REGION="${REGION:-europe-west1}"
read -r -p 'Cloud SQL destination instance [postgres14-x5u2c]: ' SQL_INSTANCE
SQL_INSTANCE="${SQL_INSTANCE:-postgres14-x5u2c}"
read -r -p 'Migration username [import_admin]: ' MIGRATION_USER
MIGRATION_USER="${MIGRATION_USER:-import_admin}"
read -r -s -p 'Migration password (DMS_1s_cool!): ' MIGRATION_PASSWORD
printf '\n'
MIGRATION_PASSWORD="${MIGRATION_PASSWORD:-DMS_1s_cool!}"
read -r -p 'Lab student email (for IAM DB user): ' STUDENT_EMAIL
[[ -n "$SOURCE_ZONE" && -n "$STUDENT_EMAIL" ]] || fail "Source zone and student email are required."

log "Enabling required APIs"
gcloud services enable datamigration.googleapis.com servicenetworking.googleapis.com sqladmin.googleapis.com compute.googleapis.com --quiet

log "Reading source VM addresses"
SOURCE_INTERNAL_IP="$(gcloud compute instances describe "$SOURCE_VM" --zone="$SOURCE_ZONE" --format='value(networkInterfaces[0].networkIP)')"
SOURCE_EXTERNAL_IP="$(gcloud compute instances describe "$SOURCE_VM" --zone="$SOURCE_ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
[[ -n "$SOURCE_INTERNAL_IP" ]] || fail "Could not find $SOURCE_VM in zone $SOURCE_ZONE."

log "Preparing PostgreSQL source VM for logical migration"
printf -v REMOTE_USER '%q' "$MIGRATION_USER"
printf -v REMOTE_PASSWORD '%q' "$MIGRATION_PASSWORD"
gcloud compute ssh "$SOURCE_VM" --zone="$SOURCE_ZONE" --quiet --command="bash -s -- $REMOTE_USER $REMOTE_PASSWORD" <<'REMOTE'
set -Eeuo pipefail
MIGRATION_USER="$1"
MIGRATION_PASSWORD="$2"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-14-pglogical
sudo python3 - <<'PY'
from pathlib import Path
p=Path('/etc/postgresql/14/main/postgresql.conf')
s=p.read_text()
for line in ['wal_level = logical','max_replication_slots = 10','max_wal_senders = 10','shared_preload_libraries = \'pglogical\'']:
    if line not in s: s += '\n' + line + '\n'
p.write_text(s)
p=Path('/etc/postgresql/14/main/pg_hba.conf')
s=p.read_text()
entry='host    all    all    0.0.0.0/0    md5'
if entry not in s: s += '\n' + entry + '\n'
p.write_text(s)
PY
sudo systemctl restart postgresql@14-main
sudo -u postgres psql -v ON_ERROR_STOP=1 -v migration_user="$MIGRATION_USER" -v migration_password="$MIGRATION_PASSWORD" <<'SQL'
SELECT format('DO $body$ BEGIN CREATE ROLE %I LOGIN PASSWORD %L REPLICATION; EXCEPTION WHEN duplicate_object THEN ALTER ROLE %I WITH PASSWORD %L REPLICATION; END $body$', :'migration_user', :'migration_password', :'migration_user', :'migration_password')\gexec
SELECT format('ALTER ROLE %I WITH SUPERUSER', :'migration_user')\gexec
\c postgres
CREATE EXTENSION IF NOT EXISTS pglogical;
\c orders
CREATE EXTENSION IF NOT EXISTS pglogical;
GRANT USAGE ON SCHEMA public TO :"migration_user";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"migration_user";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"migration_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO :"migration_user";
SQL
REMOTE

log "Creating or reusing DMS PostgreSQL connection profile"
PROFILE_ID="gsp355-postgres-source"
if ! gcloud database-migration connection-profiles describe "$PROFILE_ID" --region="$REGION" >/dev/null 2>&1; then
  gcloud database-migration connection-profiles create postgresql "$PROFILE_ID" \
    --region="$REGION" --display-name="$PROFILE_ID" --host="$SOURCE_INTERNAL_IP" \
    --port=5432 --database=orders --username="$MIGRATION_USER" --password="$MIGRATION_PASSWORD"
else
  warn "Connection profile $PROFILE_ID already exists; reusing it."
fi

log "Checking destination Cloud SQL instance"
gcloud sql instances describe "$SQL_INSTANCE" >/dev/null || fail "Cloud SQL instance $SQL_INSTANCE was not found."

cat <<SUMMARY

Source preparation and DMS connection profile are complete.

Next required lab-console actions (the lab grader requires these states):
1. In Database Migration, create a CONTINUOUS migration job from profile $PROFILE_ID
   to existing instance $SQL_INSTANCE, using VPC peering on the default network.
2. Test and start the job, wait for it to become running, then PROMOTE it.
3. In Cloud SQL > $SQL_INSTANCE > Connections, add the source VM public IP:
   ${SOURCE_EXTERNAL_IP:-<run: gcloud compute instances describe $SOURCE_VM --zone=$SOURCE_ZONE --format='value(networkInterfaces[0].accessConfigs[0].natIP)'>}
4. Add Cloud IAM database user: $STUDENT_EMAIL.
5. Grant SELECT on orders.inventory_items to that IAM user in Cloud SQL SQL editor.
6. Enable automated backups + PITR and set transaction-log retention to 6 days.
7. Capture a UTC timestamp, insert the required row, then run:
   gcloud sql instances clone $SQL_INSTANCE postgres-orders-pitr --point-in-time TIMESTAMP

The following checks are safe to run after the manual gates:
SUMMARY

log "Showing current DMS profiles and Cloud SQL status"
gcloud database-migration connection-profiles list --region="$REGION" --format='table(name.basename(),state,host)' || true
gcloud sql instances describe "$SQL_INSTANCE" --format='table(name,state,databaseVersion,ipAddresses[0].ipAddress)' || true

printf '\n\033[1;32mCLI preparation finished. Complete the listed console gates, then click Check my progress.\033[0m\n'
