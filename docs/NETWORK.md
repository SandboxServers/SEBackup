# Network & Bandwidth Guide

This document explains how SEBackup handles network transfers, bandwidth limiting, and provides recommendations for network topology in game server environments.

## Why Bandwidth Limiting Matters

Space Engineers dedicated servers are sensitive to network congestion. When a large backup archive is being transferred across the network, it can:

- Increase player latency (rubber-banding, warping)
- Cause client timeouts and disconnects
- Slow down game world synchronization
- Interfere with other game servers on the same network

SEBackup provides bandwidth throttling to prevent backup transfers from impacting game performance.

## Transfer Methods

SEBackup supports three transfer methods, in order of preference:

### 1. BITS (Background Intelligent Transfer Service)

**Best for:** Large transfers over reliable networks.

BITS is a Windows service designed for background file transfers. It automatically:
- Throttles based on available bandwidth
- Resumes interrupted transfers
- Yields to foreground network traffic

SEBackup uses BITS when available and when `max_bandwidth_mbps` is configured.

```toml
[network]
max_bandwidth_mbps = 100   # BITS will limit to this rate
```

BITS is the recommended method because it is network-aware and automatically backs off when other applications need bandwidth.

### 2. Robocopy with Inter-Packet Gap (IPG)

**Best for:** Windows-to-Windows transfers when BITS is unavailable.

Robocopy's `/IPG` flag inserts a delay (in milliseconds) between each 64KB packet. This is a simple but effective throttle.

```toml
[network]
robocopy_ipg_ms = 20   # 20ms gap between 64KB packets
```

**IPG to bandwidth approximation:**

| IPG (ms) | Approx. Bandwidth | Use Case |
|----------|-------------------|----------|
| 0 | Unlimited | Dedicated backup network |
| 5 | ~100 Mbps | Light throttling |
| 10 | ~50 Mbps | Moderate throttling |
| 20 | ~25 Mbps | Standard throttling |
| 50 | ~10 Mbps | Heavy throttling |
| 100 | ~5 Mbps | Very conservative |

These are rough approximations. Actual throughput depends on network conditions, disk I/O speed, and system load.

### 3. Copy-Item Fallback

**Best for:** Nothing (it is a last resort).

If neither BITS nor robocopy are available, SEBackup falls back to PowerShell's `Copy-Item` cmdlet. This provides no bandwidth throttling and is the slowest option. It is only used as a fallback to ensure the backup completes.

## Configuration

All network settings are in `Config\global.toml` under `[network]`:

```toml
[network]
# Maximum bandwidth in megabits per second.
# 0 = unlimited (no throttling).
# 100 = limit to 100 Mbps.
# 50 = limit to 50 Mbps.
max_bandwidth_mbps = 100

# Robocopy inter-packet gap in milliseconds.
# Only used when robocopy is the transfer method.
# 0 = no gap (full speed).
# Higher values = more throttling.
robocopy_ipg_ms = 0
```

### Choosing the Right Settings

**Dedicated backup network (separate NIC/VLAN):**
```toml
max_bandwidth_mbps = 0     # No limit needed
robocopy_ipg_ms = 0
```

**Shared network, low-population servers (< 10 players):**
```toml
max_bandwidth_mbps = 100   # Gentle throttle
robocopy_ipg_ms = 0
```

**Shared network, active servers (10-30 players):**
```toml
max_bandwidth_mbps = 50    # Moderate throttle
robocopy_ipg_ms = 20
```

**Shared network, high-population servers (30+ players):**
```toml
max_bandwidth_mbps = 25    # Conservative
robocopy_ipg_ms = 50
```

**Metered / cloud connection:**
```toml
max_bandwidth_mbps = 10    # Very conservative
robocopy_ipg_ms = 100
```

## Network Topology Recommendations

### Small Setup (1-2 servers on one machine)

```
[Internet]
     |
[Router/Firewall]
     |
[Switch] ---- [C&C + Game Server PC] ---- [NAS (optional)]
```

In this setup, the C&C and game server are the same machine (or on the same network). Backups transfer over the local network or locally on the same machine.

**Recommendation:** If the C&C and game server are the same machine, transfers happen locally and bandwidth limiting is less critical. Set `max_bandwidth_mbps = 0` since no network traffic is involved.

### Medium Setup (Multiple servers, one location)

```
[Internet]
     |
[Router/Firewall]
     |
[Managed Switch]
     |--- [C&C Server]
     |--- [Game Server 1]
     |--- [Game Server 2]
     |--- [NAS]
```

**Recommendation:** Use a gigabit switch. Set `max_bandwidth_mbps = 100` to leave headroom for game traffic. Schedule backups during low-activity hours if possible (e.g., `start_time = "04:00"`).

### Ideal Setup (Dedicated backup network)

```
[Internet]
     |
[Router/Firewall]
     |
[Game Network Switch] (1Gbps or 10Gbps)
     |--- [Game Server 1] (NIC 1: game traffic)
     |--- [Game Server 2] (NIC 1: game traffic)
     |
[Backup Network Switch] (1Gbps)
     |--- [C&C Server]
     |--- [Game Server 1] (NIC 2: backup traffic)
     |--- [Game Server 2] (NIC 2: backup traffic)
     |--- [NAS]
```

**Recommendation:** With a dedicated backup network, set `max_bandwidth_mbps = 0` (unlimited). Backup traffic will not affect game traffic because it flows over a separate physical network.

### Remote / Cloud Setup

```
[Cloud / Remote DC]          [Home Network]
  |                               |
  [Game Server]---[VPN/WAN]---[C&C Server]
                                  |
                               [NAS]
```

**Recommendation:** This setup has limited bandwidth between the game server and C&C. Use aggressive throttling (`max_bandwidth_mbps = 10-25`) and schedule backups during off-peak hours. Incremental backups are especially important here to minimize transfer sizes.

## Monitoring Transfers

### Check Active BITS Transfers

```powershell
Import-Module .\SEBackup.psd1
Get-SEBTransferStatus
```

### Cancel a Transfer

```powershell
Stop-SEBTransfer -NodeName "GamePC01" -InstanceName "PvPArena"
```

## Transfer Performance Tips

1. **Use incremental backups.** After the initial full backup, incrementals are typically 80-95% smaller. A 500MB full backup might produce 5-50MB incrementals.

2. **Compress on the node.** SEBackup compresses archives on the compute node before transferring. This means you are transferring compressed data, not raw files.

3. **Schedule during off-peak hours.** Set `start_time` in `[schedule]` to a time when few players are online (e.g., 2:00 AM - 6:00 AM local time).

4. **Use 7-Zip compression.** 7-Zip typically achieves 10-30% better compression than .NET's built-in compression, resulting in smaller transfers.

5. **Monitor with load awareness.** Enable `[load_awareness]` to automatically defer backups when the game server is under heavy load.
