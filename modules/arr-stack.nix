# modules/arr-stack.nix — VPN-connected container stack
#
# All arr containers share gluetun's network namespace. If the VPN
# drops, all containers lose connectivity — this is the kill switch.

{ config, pkgs, lib, ... }:

let
  recyclarrConfig = pkgs.writeText "recyclarr.yml" ''
    sonarr:
      sonarr-main:
        base_url: http://localhost:8989
        api_key: !env_var SONARR_API_KEY
        delete_old_custom_formats: true
        quality_definition:
          type: series
        quality_profiles:
          - trash_id: 72dae194fc92bf828f32cde7744e51a1 # WEB-1080p
            reset_unmatched_scores:
              enabled: true
          - trash_id: d1498e7d189fbe6c7110ceaabb7473e6 # WEB-2160p
            reset_unmatched_scores:
              enabled: true

    radarr:
      radarr-main:
        base_url: http://localhost:7878
        api_key: !env_var RADARR_API_KEY
        delete_old_custom_formats: true
        quality_definition:
          type: movie
        quality_profiles:
          - trash_id: 64fb5f9858489bdac2af690e27c8f42f # UHD Bluray + WEB
            reset_unmatched_scores:
              enabled: true
  '';
in

{
  virtualisation.oci-containers.containers = {

    gluetun = {
      image = "ghcr.io/qdm12/gluetun:latest@sha256:9b91146e09bfe20193860ecf7b25a45e14f0c6a0b9822c83fe3d62f2d9d52f4f";
      autoStart = true;
      volumes = [
        "/var/lib/gluetun:/gluetun"
        "/var/lib/gluetun/tmp:/tmp/gluetun"
      ];

      environment = {
        VPN_SERVICE_PROVIDER = "protonvpn";
        VPN_TYPE = "wireguard";
        # No SERVER_COUNTRIES filter — allow any server that supports port forwarding
        VPN_PORT_FORWARDING = "on";
        PORT_FORWARD_ONLY = "on";
        WIREGUARD_IMPLEMENTATION = "userspace";
        BLOCK_MALICIOUS = "off";
        WIREGUARD_MTU = "1280";
      };

      extraOptions = [
        "--privileged"
        "--device=/dev/net/tun:/dev/net/tun"
        "--env-file=/run/secrets/vpn_env"
      ];

      ports = [
        "8000:8000"   # gluetun control server
        "8888:8888"   # gluetun HTTP proxy
        "8388:8388"   # gluetun Shadowsocks
        "9091:9091"   # qBittorrent web UI (same port as Transmission was — no Caddy change needed)
        "7878:7878"   # Radarr
        "8989:8989"   # Sonarr
        "9696:9696"   # Prowlarr
        "8686:8686"   # Lidarr
        "8080:8080"   # SABnzbd
      ];
    };

    # NOTE: Use the libtorrentv1 tag, not latest.
    #
    # With Connection\Interface unset (binding to 0.0.0.0), gluetun's policy
    # routing (rule 101: no-fwmark traffic → table 51820 → tun0) routes all
    # qBittorrent traffic through the VPN. The v1 tag is kept as a conservative
    # choice; v2 may also work but has not been tested in this configuration.
    qbittorrent = {
      image = "lscr.io/linuxserver/qbittorrent:libtorrentv1@sha256:3f81663c4f0f13b74f8b44d2440041c4aead605204a07bb13c558b60df300798";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
        WEBUI_PORT = "9091";
      };
      volumes = [
        "/var/lib/qbittorrent/config:/config"
        "/var/lib/media/torrents:/downloads"
      ];
    };

    radarr = {
      image = "lscr.io/linuxserver/radarr:latest@sha256:c8a55bd83672d3b63dc20edf325277ce7dc3b69d4400568cc5bbc9e6a227ebf4";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/radarr/config:/config"
        "/var/lib/media/movies:/movies"
        "/var/lib/media/torrents:/downloads"
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    sonarr = {
      image = "lscr.io/linuxserver/sonarr:latest@sha256:76414c033f290d3c9f1f9dfad71150abe71d92592369a3377a5903d579e6e2b2";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/sonarr/config:/config"
        "/var/lib/media/tv:/tv"
        "/var/lib/media/torrents:/downloads"
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    prowlarr = {
      image = "lscr.io/linuxserver/prowlarr:latest@sha256:9ef5d8bf832edcacb6082f9262cb36087854e78eb7b1c3e1d4375056055b2d82";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/prowlarr/config:/config"
      ];
    };

    lidarr = {
      image = "lscr.io/linuxserver/lidarr:latest@sha256:dbffcf91da47d48e09e613857032c95a62755b928a71a7718688e3ab03fbbd26";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/lidarr/config:/config"
        "/var/lib/media/music:/music"
        "/var/lib/media/torrents:/downloads"
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    recyclarr = {
      image = "ghcr.io/recyclarr/recyclarr:latest@sha256:55afe316d3e4e4e3b9120cef7c79436b1b5311f6a18d4ef4b7653e720499c90a";
      autoStart = true;
      dependsOn = [ "gluetun" "radarr" "sonarr" ];
      extraOptions = [
        "--network=container:gluetun"
        "--env-file=${config.sops.secrets.recyclarr_env.path}"
      ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/recyclarr/config:/config"
        "${recyclarrConfig}:/config/recyclarr.yml:ro"
      ];
    };

    sabnzbd = {
      image = "lscr.io/linuxserver/sabnzbd:latest@sha256:15b1220aaa1f8ff428790a3d56f5ca2822427ea0b33e978eee43554e42579d0f";
      autoStart = true;
      dependsOn = [ "gluetun" ];
      extraOptions = [ "--network=container:gluetun" ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/sabnzbd/config:/config"
        "/var/lib/media/usenet:/sabnzbd"
      ];
    };

    jellyfin = {
      image = "ghcr.io/linuxserver/jellyfin:latest@sha256:0a2f7e2c1c34e1a0e553b8521208ac1cc9ffa6a0efc2cf4acb4a45229b390e65";
      autoStart = true;
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "America/Los_Angeles";
      };
      ports = [
        "8096:8096"
      ];
      volumes = [
        "/var/lib/jellyfin/config:/config"
        "/var/lib/media/movies:/movies"
        "/var/lib/media/tv:/tv"
        "/var/lib/media/music:/music"
      ];
    };
  };

  # Seed qBittorrent.conf before the container starts, then wait for gluetun's
  # VPN tunnel to be established.
  #
  # WHY Session\Interface IS SET TO THE IP, NOT THE NAME:
  # Three approaches were tried:
  #   1. Interface=tun0 (name): libtorrent fails to bind to TUN devices by name
  #      → zero UDP sockets, no DHT.
  #   2. Interface="" (any): libtorrent enumerates physical interfaces only,
  #      creating sockets on eth0 (10.88.0.12). gluetun's policy rule 100 routes
  #      traffic from 10.88.0.12 → table 200 → eth0, which iptables then DROPs
  #      for external destinations. DHT still 0 nodes.
  #   3. Interface=10.2.0.2 (tun0's IP, resolved dynamically in preStart): libtorrent
  #      binds directly to the IP — this works. Traffic from 10.2.0.2 hits policy
  #      rule 101 (non-fwmark → table 51820 → default dev tun0), routing correctly
  #      through the VPN. DHT bootstraps successfully.
  # The IP is resolved each restart via `podman exec gluetun ip addr show tun0`,
  # with fallback to parsing WIREGUARD_ADDRESSES from the vpn_env sops secret.
  #
  # WHY THE STARTUP WAIT MATTERS:
  # Waiting for the forwarded_port file ensures the WireGuard tunnel is active
  # and port forwarding is established before qBittorrent initializes libtorrent.
  # Without this, qBittorrent would start with no active VPN, and gluetun's
  # kill switch would block all peer traffic until the tunnel came up.
  systemd.services.podman-qbittorrent = {
    # Expose QBT_USERNAME / QBT_PASSWORD to preStart so we can generate the
    # PBKDF2 hash and write it into qBittorrent.conf before the container
    # starts — preventing the linuxserver init from overwriting with an
    # unknown hardcoded default.
    serviceConfig.EnvironmentFile = config.sops.secrets.qbt_credentials.path;

    preStart = ''
      ${pkgs.python3}/bin/python3 - << 'PYEOF'
import hashlib, secrets, base64, os, re, sys, subprocess

conf_dir = "/var/lib/qbittorrent/config/qBittorrent"
conf_path = conf_dir + "/qBittorrent.conf"
os.makedirs(conf_dir, exist_ok=True)

username = os.environ.get("QBT_USERNAME", "admin")
password = os.environ.get("QBT_PASSWORD", "")
if not password:
    print("QBT_PASSWORD not set in qbt_credentials secret", file=sys.stderr)
    sys.exit(1)

# Generate PBKDF2-SHA512 hash in qBittorrent's @ByteArray format.
# Writing this before the container starts prevents the linuxserver init
# script from regenerating an unknown default password.
salt = secrets.token_bytes(16)
key = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt, 100000, dklen=64)
pw_hash = "@ByteArray(" + base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode() + ")"

pw_line   = 'WebUI\\Password_PBKDF2="' + pw_hash + '"'
user_line = "WebUI\\Username=" + username
auth_line = "WebUI\\LocalHostAuth=false"

# Resolve tun0's IP address for libtorrent binding.
#
# We cannot use Interface=tun0 (by name): libtorrent fails to bind to TUN
# devices by name, leaving qBittorrent with zero UDP sockets and no DHT.
# We cannot use Interface="" (any): libtorrent enumerates physical interfaces
# only, creating sockets on eth0 (10.88.0.12) which gluetun's iptables drops
# (rule 100: from 10.88.0.12 → table 200 → eth0 → DROP for external traffic).
# Binding to tun0's IP directly (10.2.0.2) works: libtorrent creates sockets
# on that IP, and gluetun's policy routing (rule 101: non-fwmark → table 51820
# → default dev tun0) correctly routes all outbound traffic through the VPN.
tun0_ip = None

# Method 1: ask the running gluetun container (most reliable)
try:
    r = subprocess.run(
        ["podman", "exec", "gluetun", "ip", "-4", "addr", "show", "dev", "tun0"],
        capture_output=True, text=True, timeout=10
    )
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", r.stdout)
    if m:
        tun0_ip = m.group(1)
except Exception as e:
    print(f"Warning: podman exec gluetun failed: {e}", file=sys.stderr)

# Method 2: parse WIREGUARD_ADDRESSES from vpn_env sops secret
if not tun0_ip:
    try:
        with open("/run/secrets/vpn_env") as f:
            for line in f:
                m = re.match(r"WIREGUARD_ADDRESSES=(\d+\.\d+\.\d+\.\d+)", line.strip())
                if m:
                    tun0_ip = m.group(1)
                    break
    except Exception:
        pass

if tun0_ip:
    print(f"tun0 IP for qBittorrent binding: {tun0_ip}")
    iface_line = "Session\\Interface=" + tun0_ip + "\n"
else:
    print("Warning: could not determine tun0 IP; qBittorrent will bind to all interfaces", file=sys.stderr)
    iface_line = ""

def ensure_bittorrent_iface(content, iface_line):
    """Insert Session\\Interface into [BitTorrent] section, or append section."""
    if not iface_line:
        return content
    if "[BitTorrent]\n" in content:
        return content.replace("[BitTorrent]\n", "[BitTorrent]\n" + iface_line, 1)
    return content + "\n[BitTorrent]\n" + iface_line

if not os.path.exists(conf_path):
    with open(conf_path, "w") as f:
        f.write("[Preferences]\n")
        f.write(auth_line + "\n")
        f.write(user_line + "\n")
        f.write(pw_line + "\n")
        if iface_line:
            f.write("\n[BitTorrent]\n")
            f.write(iface_line)
    print("Seeded fresh qBittorrent.conf")
else:
    with open(conf_path, "r") as f:
        content = f.read()

    # Always clear IP ban — bans survive restarts and create a painful loop
    content = re.sub(r"^WebUI\\BanList=.*\n?", "", content, flags=re.MULTILINE)

    # Strip all interface settings (qBittorrent 4.x [Preferences] and 5.x
    # [BitTorrent] locations), then re-add Session\Interface with the IP.
    content = re.sub(r"^Connection\\Interface.*\n?", "", content, flags=re.MULTILINE)
    content = re.sub(r"^Connection\\InterfaceName.*\n?", "", content, flags=re.MULTILINE)
    content = re.sub(r"^Connection\\InterfaceAddress.*\n?", "", content, flags=re.MULTILINE)
    content = re.sub(r"^Session\\Interface=.*\n?", "", content, flags=re.MULTILINE)
    content = re.sub(r"^Session\\InterfaceName=.*\n?", "", content, flags=re.MULTILINE)
    content = ensure_bittorrent_iface(content, iface_line)

    # Always sync password from sops secret (re.sub replacement needs \\\\ for one \)
    pw_repl = 'WebUI\\\\Password_PBKDF2="' + pw_hash + '"'
    if re.search(r"^WebUI\\Password_PBKDF2=", content, re.MULTILINE):
        content = re.sub(r"^WebUI\\Password_PBKDF2=.*", pw_repl, content, flags=re.MULTILINE)
    else:
        content = content.replace("[Preferences]\n", "[Preferences]\n" + pw_line + "\n", 1)

    # Always sync username from sops secret
    user_repl = "WebUI\\\\Username=" + username
    if re.search(r"^WebUI\\Username=", content, re.MULTILINE):
        content = re.sub(r"^WebUI\\Username=.*", user_repl, content, flags=re.MULTILINE)
    else:
        content = content.replace("[Preferences]\n", "[Preferences]\n" + user_line + "\n", 1)

    # Ensure localhost auth bypass (prevents arr apps from triggering bans)
    if not re.search(r"^WebUI\\LocalHostAuth=", content, re.MULTILINE):
        content = content.replace("[Preferences]\n", "[Preferences]\n" + auth_line + "\n", 1)

    with open(conf_path, "w") as f:
        f.write(content)
    print("Updated qBittorrent.conf")
PYEOF

      echo "Waiting for gluetun VPN to establish (up to 90s)..."
      for i in $(seq 1 30); do
        if [ -s "/var/lib/gluetun/tmp/forwarded_port" ]; then
          PORT=$(cat /var/lib/gluetun/tmp/forwarded_port | tr -d '[:space:]')
          echo "gluetun VPN established, forwarded port: $PORT"
          break
        fi
        sleep 3
      done
    '';
  };

  # Sync the gluetun-forwarded port into qBittorrent every 5 minutes.
  # Without this, qBittorrent announces the wrong port to trackers and shows
  # "Firewalled" status, which severely limits peer connectivity.
  #
  # Credentials (QBT_USERNAME / QBT_PASSWORD) come from the qbt_credentials
  # sops secret — the same secret the preStart uses to generate the WebUI
  # password hash. Update the secret and redeploy to change credentials.
  systemd.services.qbittorrent-port-sync = {
    description = "Sync gluetun forwarded port to qBittorrent";
    after = [ "podman-gluetun.service" "podman-qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "30s";
      EnvironmentFile = "/run/secrets/qbt_credentials";
    };

    script = ''
      PORT_FILE="/var/lib/gluetun/tmp/forwarded_port"
      COOKIE_FILE=$(${pkgs.coreutils}/bin/mktemp)

      trap "${pkgs.coreutils}/bin/rm -f $COOKIE_FILE" EXIT

      if [ ! -f "$PORT_FILE" ]; then
        echo "Port file not found yet, waiting..."
        sleep 30
        exit 0
      fi

      PORT=$(cat "$PORT_FILE" | tr -d '[:space:]')

      if [ -z "$PORT" ] || [ "$PORT" = "0" ]; then
        echo "No forwarded port available yet, waiting..."
        sleep 30
        exit 0
      fi

      echo "Forwarded port: $PORT"

      LOGIN=$(${pkgs.curl}/bin/curl -sf --max-time 10 \
        -c "$COOKIE_FILE" \
        --data "username=$QBT_USERNAME&password=$QBT_PASSWORD" \
        http://localhost:9091/api/v2/auth/login 2>&1 || echo "curl_error")

      if [ "$LOGIN" != "Ok." ]; then
        echo "qBittorrent login failed: $LOGIN"
        sleep 30
        exit 0
      fi

      ${pkgs.curl}/bin/curl -sf \
        -b "$COOKIE_FILE" \
        --data "json={\"listen_port\":$PORT}" \
        http://localhost:9091/api/v2/app/setPreferences

      echo "Updated qBittorrent listening port to $PORT"

      ${pkgs.curl}/bin/curl -sf \
        -b "$COOKIE_FILE" \
        http://localhost:9091/api/v2/auth/logout || true

      sleep 300
    '';
  };

  systemd.services.podman-gluetun = {
    postStart = ''
      sleep 5
      ${pkgs.iproute2}/bin/ip link set tun0 mtu 1280 2>/dev/null || true
      ${pkgs.ethtool}/bin/ethtool -K tun0 gso off gro off 2>/dev/null || true
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent/config 0755 brian users -"
    "d /var/lib/radarr/config 0755 brian users -"
    "d /var/lib/sonarr/config 0755 brian users -"
    "d /var/lib/prowlarr/config 0755 brian users -"
    "d /var/lib/media/torrents 0755 brian users -"
    "d /var/lib/media/movies 0755 brian users -"
    "d /var/lib/media/tv 0755 brian users -"
    "d /var/lib/gluetun/auth 0755 brian users -"
    "d /var/lib/gluetun/tmp 0755 brian users -"
    "d /var/lib/media/torrents/complete/radarr 0755 brian users -"
    "d /var/lib/media/torrents/complete/sonarr 0755 brian users -"
    "d /var/lib/media/torrents/complete/lidarr 0755 brian users -"
    "f /var/lib/gluetun/auth/config.toml 0644 brian users -"
    "d /var/lib/lidarr/config 0755 brian users -"
    "d /var/lib/recyclarr/config 0755 brian users -"
    "d /var/lib/media/music 0755 brian users -"
    "d /var/lib/jellyfin/config 0755 brian users -"
    "d /var/lib/sabnzbd/config 0755 brian users -"
    "d /var/lib/media/usenet 0755 brian users -"
    "d /var/lib/media/usenet/incomplete 0755 brian users -"
    "d /var/lib/media/usenet/complete 0755 brian users -"
  ];

  sops.secrets.recyclarr_env = {};
}
