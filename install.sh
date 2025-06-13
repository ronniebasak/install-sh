#!/bin/bash

# Install essential utilities
dnf update -y
dnf install -y epel-release
dnf makecache
dnf install -y htop vim nano bash-completion openssh net-tools git curl wget unzip firewalld fail2ban policycoreutils-python-utils setroubleshoot setools-console

# Start and enable firewalld
systemctl start firewalld
systemctl enable firewalld

# Secure SSH Access
# Disable SSH root login
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# Prompt for a new SSH port
ssh_port=2222
read -p "Enter a new SSH port (default 2222): " ssh_port < /dev/tty
ssh_port=${ssh_port:-2222}

# Update the SSH port in sshd_config
sed -i "s/^#\?Port .*/Port $ssh_port/" /etc/ssh/sshd_config

# Adjust SELinux policy to allow the new SSH port
semanage port -a -t ssh_port_t -p tcp $ssh_port || semanage port -m -t ssh_port_t -p tcp $ssh_port

# Update firewall to allow the new SSH port
firewall-cmd --permanent --add-port=${ssh_port}/tcp
firewall-cmd --reload

# Restart sshd
systemctl restart sshd

# Install and Configure Fail2ban
systemctl enable --now fail2ban
cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/secure
maxretry = 5
EOF
systemctl restart fail2ban

# Set Up Time Synchronization
dnf install -y chrony
systemctl enable --now chronyd

# Configure Automatic Security Updates
dnf install -y dnf-automatic
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
sed -i 's/update_cmd = default/update_cmd = security/' /etc/dnf/automatic.conf
systemctl enable --now dnf-automatic.timer

# Install Docker
dnf install -y dnf-plugins-core
dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io
systemctl start docker
systemctl enable docker

# Create a Docker network named 'npm'
docker network create npm
echo "Docker network 'npm' created."

# Prompt to install Portainer or Portainer Agent
portainer_choice="none"
read -p "Do you want to install Portainer or Portainer Agent? (portainer/agent/none): " portainer_choice < /dev/tty

case "$portainer_choice" in
  portainer)
    docker volume create portainer_data
    docker run -d -p 9443:9443 --name=portainer --restart=always \
      --network=npm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data portainer/portainer-ce:latest
    echo "Portainer installed and connected to 'npm' network, accessible on port 9443."
    ;;
  agent)
    docker run -d -p 9001:9001 --name portainer_agent --restart=always \
      --network=npm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /var/lib/docker/volumes:/var/lib/docker/volumes \
      portainer/agent
    echo "Portainer Agent installed and connected to 'npm' network, accessible on port 9001."
    ;;
  none)
    echo "Skipping Portainer installation."
    ;;
  *)
    echo "Invalid option. Skipping Portainer installation."
    ;;
esac

# Create directories for Nginx Proxy Manager
mkdir -p /opt/nginx-proxy-manager/{data,letsencrypt}

# Create Docker Compose file for Nginx Proxy Manager
cat <<EOF > /opt/nginx-proxy-manager/docker-compose.yml
version: '3'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '127.0.0.1:81:81'
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - npm
networks:
  npm:
    external: true
EOF

# Deploy Nginx Proxy Manager
cd /opt/nginx-proxy-manager
docker compose up -d
echo "Nginx Proxy Manager deployed, connected to 'npm' network, and accessible on ports 80, 81 (localhost), and 443."

# Configure firewall for HTTP and HTTPS
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload
echo "Firewall configured to allow HTTP and HTTPS traffic."

# Install ClamAV for Malware Scanning
dnf install -y clamav clamav-update
freshclam
(crontab -l 2>/dev/null; echo "0 3 * * * clamscan -r /home") | crontab -
echo "ClamAV installed and daily scan scheduled."

# Configure Log Rotation for Docker Logs
cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

# Set Up System Resource Limits
echo "* hard nofile 65535" >> /etc/security/limits.conf
echo "* soft nofile 65535" >> /etc/security/limits.conf

# Install Additional Security Tools (RKHunter)
dnf install -y rkhunter
rkhunter --update
rkhunter --propupd
(crontab -l 2>/dev/null; echo "0 1 * * * /usr/bin/rkhunter --check --quiet") | crontab -
echo "RKHunter installed and daily scan scheduled."

# Enable BBR Congestion Control for Network Performance
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# Install and Enable Auditd for Audit Logging
dnf install -y auditd
systemctl enable --now auditd

# Set System Timezone
timezone="UTC"
read -p "Enter your timezone (default 'UTC'): " timezone < /dev/tty
timezone=${timezone:-UTC}
timedatectl set-timezone "$timezone"

# Create a MOTD Banner
cat <<EOF > /etc/motd
Unauthorized access is prohibited. All actions are monitored.
EOF

# Clean Up Unnecessary Packages
dnf autoremove -y

# Install the user addition script
cat <<'EOF' > /usr/local/bin/add_secure_user
#!/bin/bash

read -p "Enter the username: " username < /dev/tty
if id "$username" &>/dev/null; then
  echo "User '$username' already exists. Exiting."
  exit 1
fi

useradd -m -G wheel,docker "$username"
passwd "$username"

mkdir -p /home/$username/.ssh
chmod 700 /home/$username/.ssh

echo "Paste the SSH public key for user '$username' and press Enter:"
read -r ssh_key < /dev/tty
echo "$ssh_key" > /home/$username/.ssh/authorized_keys
chmod 600 /home/$username/.ssh/authorized_keys
chown -R $username:$username /home/$username/.ssh

echo "Match User $username" >> /etc/ssh/sshd_config
echo "  PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "  AuthenticationMethods publickey" >> /etc/ssh/sshd_config

systemctl restart sshd
echo "User '$username' added with SSH key authentication only."
EOF

chmod +x /usr/local/bin/add_secure_user
echo "User addition script 'add_secure_user' installed to /usr/local/bin."

# Ensure SELinux is enabled and in enforcing mode
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setenforce 1

echo "SELinux is set to enforcing mode."

# Final Reboot (If Necessary)
read -p "Reboot the system now to apply all changes (recommended)? (y/n): " reboot_choice < /dev/tty
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    reboot
fi

echo "Setup completed successfully."