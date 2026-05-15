# bootiso-remote — Copy ISO to Remote Host and Boot

Boot a QOS ISO on any remote Linux system using `bootiso` and kexec.

## Quick Start

```bash
# Boot default server ISO on remote host
make bootiso-remote HOST=192.168.1.100

# Boot with custom credentials
make bootiso-remote HOST=myhost.com USER=admin PASS=secret

# Boot desktop ISO with custom SSH port
make bootiso-remote HOST=192.168.1.50 PORT=2222 ISO=dist/qos-desktop.iso
```

## Usage

### Via Make Command

```bash
make bootiso-remote HOST=<host> [PORT=<port>] [USER=<user>] [PASS=<pass>] [ISO=<iso>]
```

**Parameters:**
| Param | Default | Description |
|-------|---------|-------------|
| `HOST` | *required* | Remote host IP or hostname |
| `PORT` | 22 | SSH port |
| `USER` | emo | SSH username |
| `PASS` | emo2500 | SSH password |
| `ISO` | dist/qos-server.iso | Local ISO file path |

### Via Direct Script Call

```bash
bash builder/tools/bootiso-remote.sh -h 192.168.1.100 -p 2222 -u admin -P secret -i dist/qos-desktop.iso
```

## How It Works

1. **Validates** — Checks host is accessible and ISO exists locally
2. **Copies** — Transfers ISO to remote host via SCP (encrypted, password-less with sshpass)
3. **Boots** — Executes `bootiso` on remote host via SSH
4. **Hands Off** — kexec loads and executes ISO kernel (no UEFI POST)
5. **Returns** — On reboot, system returns to original disk

## Workflow Example

### Scenario: Boot desktop ISO on production server

```bash
# 1. Build desktop ISO (if not already built)
make desktop

# 2. Boot it on your server at 192.168.1.50
make bootiso-remote HOST=192.168.1.50 ISO=dist/qos-desktop.iso

# 3. System reboots into QOS desktop
# 4. On shutdown, it reboots to the original system
```

### Scenario: Test on remote cluster node

```bash
# SSH-configured node (no password)
make bootiso-remote HOST=node1.cluster.local USER=centos

# Or with custom credentials (default: emo/emo2500)
make bootiso-remote \
  HOST=192.168.1.100 \
  PORT=2222 \
  USER=emo \
  PASS=emo2500 \
  ISO=dist/qos-server.iso
```

## Requirements

**On Build Machine:**
- `sshpass` — Enable password-less SSH login
- `ssh`, `scp` — OpenSSH client tools

**On Remote Host:**
- `dropbear` or `openssh` — SSH server
- `emo` user with `emo2500` password (or sudo access)
- Built QOS system with bootiso installed

## Notes

- **ISO Size** — Server ISO ~260MB, Desktop ISO ~500MB (transfer takes 1-5 minutes on typical networks)
- **Credentials** — Uses sshpass for automation; store in a `~/.env` file for reuse:
  ```bash
  # ~/.env
  export HOST=192.168.1.100
  export PORT=22
  export USER=emo
  export PASS=emo2500
  
  # Usage: source ~/.env && make bootiso-remote ISO=...
  ```
- **SSH Key** — If you configure SSH keys on the host, you can skip password:
  ```bash
  # After SSH key setup
  make bootiso-remote HOST=myhost.com  # Requires openssh (not dropbear)
  ```
- **Network** — Ensure network connectivity; firewalls should allow SSH (port 22 or custom)

## Troubleshooting

### "Connection refused" or "Connection timed out"
- Check host is reachable: `ping $HOST`
- Verify SSH port: `ssh -p $PORT $USER@$HOST whoami`
- Ensure dropbear/SSH is running on remote

### "Permission denied (publickey,password)"
- Verify password is correct: `sshpass -p $PASS ssh -p $PORT $USER@$HOST echo ok`
- Check user has root or sudo access

### "bootiso: command not found"
- Host doesn't have QOS with bootiso installed
- Build and deploy QOS first: `make server`

### ISO transfer is slow
- Check network bandwidth: `iperf3` to benchmark
- Consider pre-staging the ISO on the remote host
- Use `-r /mnt/iso` to copy to a faster location

## Advanced Usage

### Pre-stage ISO on multiple hosts

```bash
for host in 192.168.1.{100..110}; do
  make bootiso-remote HOST=$host ISO=dist/qos-server.iso &
done
wait
```

### Boot and run commands immediately

```bash
# After bootiso hands off, SSH back in when ready
make bootiso-remote HOST=192.168.1.100
sleep 30  # Wait for system to boot
sshpass -p emo2500 ssh -p 2222 root@192.168.1.100 "qos-install --auto /dev/vda"
```

### Monitor boot via serial console

```bash
# On remote host (if configured)
sudo tee -a /etc/s6-rc.d/bootiso/type >/dev/null <<EOF
longrun
EOF
```

## See Also

- `bootiso --help` — Show bootiso usage on target system
- `make bootiso-help` — Show this script's usage
- `docs/boot.md` — Technical details on kexec boot mechanism
