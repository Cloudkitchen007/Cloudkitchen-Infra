#!/bin/bash
set -ex
dnf update -y
dnf install -y postgresql15-server
postgresql-setup --initdb
systemctl enable postgresql
systemctl start postgresql

# Set password and create database
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${db_password}';"
sudo -u postgres psql -c "CREATE DATABASE ${db_name};"

# Allow remote connections
echo "host all all 10.0.0.0/8 md5" >> /var/lib/pgsql/data/pg_hba.conf
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf
systemctl restart postgresql