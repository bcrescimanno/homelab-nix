# modules/nut.nix — Network UPS Tools
#
# Monitors the Tripp Lite SMC15002URM UPS connected to rivendell via USB.
# Runs in netserver mode so Home Assistant can connect via the NUT integration.
#
# Secrets required in secrets/rivendell.yaml:
#   nut_upsmon_password  — internal upsmon user password
#   nut_ha_password      — Home Assistant monitor user password
#
# Port: 3493 (NUT default)
# After deploy, configure HA via Settings → Devices → Add Integration → NUT
#   Host: localhost (or rivendell), Port: 3493
#   Username: homeassistant, Password: <nut_ha_password>

{ config, lib, pkgs, ... }:

let
  wake = config.homelab.ups.wakeOnRestore;
  rsd = config.homelab.ups.remoteShutdown;

  upsName = "tripplite";

  # Same literal and reasoning as reboot-policy.nix and grafana.nix: ntfy is on
  # this host, and a power event is exactly when name resolution may not be up.
  ntfyUrl = "http://10.0.1.9:2586/homelab";
  # Publish UPS events to ntfy via the LAN port (bypasses NPM — more reliable
  # during a real power event when NPM itself might be restarting).
  # NOTIFYTYPE and UPSNAME are set by upsmon before calling this script.
  nutNotify = pkgs.writeShellScript "nut-ntfy-notify" ''
    case "$NOTIFYTYPE" in
      ONBATT)   PRIORITY=4; TAGS=rotating_light ;;
      LOWBATT)  PRIORITY=5; TAGS=warning ;;
      SHUTDOWN) PRIORITY=5; TAGS=skull ;;
      COMMBAD)  PRIORITY=4; TAGS=warning ;;
      ONLINE)   PRIORITY=3; TAGS=white_check_mark ;;
      COMMOK)   PRIORITY=3; TAGS=white_check_mark ;;
      *)        PRIORITY=3; TAGS=electric_plug ;;
    esac

    ${pkgs.curl}/bin/curl -s \
      -H "Title: UPS: $NOTIFYTYPE" \
      -H "Priority: $PRIORITY" \
      -H "Tags: $TAGS" \
      -d "UPS $UPSNAME: $NOTIFYTYPE" \
      http://rivendell:2586/homelab
  '';

  # ---------------------------------------------------------------------------
  # Remote shutdown — for boxes that cannot run upsmon at all
  # ---------------------------------------------------------------------------
  #
  # erebor is a UNAS Pro 4 running UniFi OS. It has no NUT client and cannot be
  # an upsmon secondary, so before this it ran until the UPS output stopped and
  # took an UNCLEAN POWER CUT on a 4-disk Btrfs RAID 6 — every single outage.
  # That was the largest remaining exposure in the power chain.
  #
  # It is Debian 11 with systemd underneath (verified), so `poweroff` over SSH is
  # all it takes. rivendell is the right caller: it is Tier 0, holds upsmon
  # primary, and is the only host that sees the battery directly.
  #
  # ORDERING IS THE WHOLE DIFFICULTY, and getting it wrong makes things worse.
  # erebor's NFS shares are mounted `hard` (the default), so IO to a vanished
  # server blocks forever in D state. If erebor powers off while a consumer still
  # has it mounted, that consumer hangs — and at LOWBATT it would then fail to
  # unmount, stall its own shutdown past systemd's timeout, and take the very
  # unclean cut this is meant to prevent. So:
  #
  #   * `unmountFirst` handles RIVENDELL'S OWN mounts. It has two live ones,
  #     /var/backup/erebor (restic) and /var/lib/media/music (Music Assistant).
  #     A lazy unmount detaches the tree even with open handles, so a running
  #     Music Assistant cannot block the sequence.
  #   * `waitForDown` handles the OTHER hosts. orthanc sheds at 5 minutes and
  #     pirateship sheds on charge ahead of this threshold, so both should
  #     already be gone; this verifies it rather than assuming.
  #
  # `waitMinutes` then bounds that wait, because a consumer that never sheds must
  # not deadlock the sequence and leave erebor to be cut anyway. Past the grace
  # we proceed and say so in the push: a hung NFS client on a host that is itself
  # minutes from shutdown is a far smaller problem than an unclean array.
  #
  # AUTHENTICATION: a dedicated sops key (erebor_shutdown_key), NOT rivendell's
  # host key — same pattern as nix_remote_builder_key. The matching public key
  # must be authorized on erebor. **Add it through the UniFi console's SSH-key
  # UI, not by hand-editing /root/.ssh/authorized_keys**, or a UniFi OS update
  # will quietly drop it and this will silently stop working.
  #
  # Failure is reported, never silent: an SSH that does not return success sends
  # a priority-5 push naming erebor, because the whole point is knowing the array
  # was protected.
  shutdownScript = pkgs.writeShellScript "homelab-ups-remote-shutdown" ''
    set -u
    PATH=${lib.makeBinPath [
      config.power.ups.package
      pkgs.openssh
      pkgs.util-linux
      pkgs.iputils
      pkgs.coreutils
      pkgs.curl
    ]}

    STATE=/var/lib/homelab-ups-remote-shutdown
    OB_SINCE=$STATE/onbatt-since
    TRIGGERED=$STATE/triggered-at
    DONE=$STATE/done

    notify() {
      curl -s --connect-timeout 5 --max-time 20 \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" \
        ${ntfyUrl} || true
    }

    # Unknown UPS state is never a reason to power down a NAS.
    if ! status=$(upsc ${upsName}@localhost ups.status 2>/dev/null); then
      exit 0
    fi

    case "$status" in
      *OB*) ;;
      *)
        # Mains is back. Reset so a later outage can trigger again.
        rm -f "$OB_SINCE" "$TRIGGERED" "$DONE"
        exit 0
        ;;
    esac

    # Already handled this outage; do not spam a powered-off box.
    [ -f "$DONE" ] && exit 0

    now=$(date +%s)
    [ -f "$OB_SINCE" ] || echo "$now" > "$OB_SINCE"
    elapsed=$(( now - $(cat "$OB_SINCE") ))

    charge=$(upsc ${upsName}@localhost battery.charge 2>/dev/null || echo "")

    reason=""
    ${lib.optionalString (rsd.afterMinutes != null) ''
      if [ "$elapsed" -ge ${toString (rsd.afterMinutes * 60)} ]; then
        reason="on battery for $(( elapsed / 60 ))m"
      fi
    ''}
    ${lib.optionalString (rsd.belowCharge != null) ''
      if [ -n "$charge" ] && [ "''${charge%%.*}" -le ${toString rsd.belowCharge} ]; then
        reason="battery at ''${charge}%"
      fi
    ''}
    [ -z "$reason" ] && exit 0

    # Stamp when the trigger first fired. The consumer grace is measured from
    # HERE, not from the start of the outage: with a charge-based trigger the
    # two are unrelated, and basing the grace on outage length would either
    # expire before the trigger even fired or wait far too long.
    [ -f "$TRIGGERED" ] || echo "$now" > "$TRIGGERED"
    waited=$(( now - $(cat "$TRIGGERED") ))

    # Are erebor's other NFS consumers gone yet?
    stillup=""
    ${lib.concatMapStringsSep "\n" (h: ''
      ping -c1 -W2 ${h} >/dev/null 2>&1 && stillup="$stillup ${h}"
    '') rsd.waitForDown}

    if [ -n "$stillup" ]; then
      if [ "$waited" -lt ${toString (rsd.waitMinutes * 60)} ]; then
        echo "waiting for NFS consumers to shut down:$stillup (''${waited}s elapsed)"
        exit 0
      fi
      echo "grace expired; proceeding with$stillup still up"
      notify "UPS: shutting down erebor anyway" 4 warning \
        "Still up:$stillup. Proceeding after the ${toString rsd.waitMinutes}m grace — a hung NFS client on a host that is itself about to shut down beats an unclean Btrfs array."
    fi

    # Detach our own mounts first so nothing here blocks on a vanished server.
    ${lib.concatMapStringsSep "\n" (m: ''
      if mountpoint -q ${m}; then
        echo "lazily unmounting ${m}"
        umount -l ${m} || echo "could not unmount ${m}, continuing"
      fi
    '') rsd.unmountFirst}

    ${lib.concatMapStringsSep "\n" (t: ''
      echo "powering off ${t.name} ($reason)"
      if ssh -i ${rsd.keyFile} \
           -o BatchMode=yes -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
           ${t.user}@${t.host} 'poweroff' >/dev/null 2>&1; then
        notify "UPS: ${t.name} shutting down cleanly" 4 floppy_disk \
          "${t.name} was told to power off ($reason, charge ''${charge:-unknown}%) so its array is not cut mid-write."
      else
        notify "UPS: FAILED to shut down ${t.name}" 5 warning \
          "SSH poweroff to ${t.name} did not succeed ($reason). Its array will take an unclean cut when the battery runs out. Check that the erebor_shutdown_key public key is still authorized in the UniFi console — a UniFi OS update can drop it."
      fi
    '') rsd.targets}

    touch "$DONE"
  '';

  # ---------------------------------------------------------------------------
  # Wake-on-restore
  # ---------------------------------------------------------------------------
  #
  # Hosts shed during an outage (modules/nut-secondary.nix, homelab.ups.shed*)
  # power themselves off with `systemctl poweroff` while the UPS is still
  # supplying AC. Their BIOS therefore never sees an AC transition and *Restore
  # on AC Power Loss* cannot bring them back — a magic packet is the only thing
  # that will. This is the sender half; the target must arm WoL itself (see
  # networking.interfaces.<if>.wakeOnLan in hosts/orthanc.nix).
  #
  # THREE GUARDS, because a spurious wake is genuinely annoying — it would
  # resurrect a host Brian deliberately powered off for maintenance:
  #
  #   1. Only ever wake after an outage THIS HOST WITNESSED. No recorded OB
  #      period means no wake, full stop. A host that is merely unreachable on
  #      mains power is none of our business.
  #   2. Only if that outage lasted at least `minOutageMinutes` — long enough
  #      that the target would actually have shed. A 30-second blip plus an
  #      unreachable host means the host is down for some other reason.
  #   3. Only once mains has been continuously present for `stableMinutes`.
  #      This is the anti-flap buffer: utilities routinely bounce power several
  #      times while restoring, and each bounce restarts the clock, so we do not
  #      spend packets — or wake a host into a second brownout.
  #
  # The longest outage segment is remembered, not the most recent one. Without
  # that, a 20-minute outage followed by a 10-second flicker would overwrite the
  # recorded duration with 10s, fail guard 2, and silently never wake anything.
  #
  # State lives in /var/lib, NOT /run: in a full-battery-drain outage rivendell
  # shuts down too, and after it boots it must still remember that it owes a
  # wake. A reboot must not erase the obligation.
  #
  # Attempts are bounded and spaced. If the target still has not answered after
  # the last one, that is reported as a FAILURE needing hands — most likely the
  # battery ran flat, the NIC lost standby power and with it the WoL arming, in
  # which case only the BIOS setting or a physical press will do it.
  wakeScript = pkgs.writeShellScript "homelab-ups-wake" ''
    set -u
    PATH=${lib.makeBinPath [
      config.power.ups.package
      pkgs.wakeonlan
      pkgs.iputils
      pkgs.coreutils
      pkgs.curl
    ]}

    STATE=/var/lib/homelab-ups-wake
    OB_SINCE=$STATE/ob-since
    OUTAGE_LEN=$STATE/outage-len
    OL_SINCE=$STATE/ol-since

    notify() {
      curl -s --connect-timeout 5 --max-time 20 --retry 3 --retry-delay 5 \
        -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4" \
        ${ntfyUrl} || true
    }

    # An unreachable UPS tells us nothing. Never act, never forget.
    if ! status=$(upsc ${upsName}@localhost ups.status 2>/dev/null); then
      exit 0
    fi

    now=$(date +%s)

    case "$status" in
      *OB*)
        # Outage in progress. Start the clock if this is the leading edge, and
        # cancel any stability buffer that was accumulating — this is the flap
        # case, and it must reset.
        [ -f "$OB_SINCE" ] || echo "$now" > "$OB_SINCE"
        rm -f "$OL_SINCE"
        exit 0
        ;;
    esac

    # Mains is present from here on.

    if [ -f "$OB_SINCE" ]; then
      # Trailing edge: an outage just ended. Record it, keeping the LONGEST
      # segment seen rather than the most recent.
      len=$(( now - $(cat "$OB_SINCE") ))
      prev=$(cat "$OUTAGE_LEN" 2>/dev/null || echo 0)
      [ "$len" -gt "$prev" ] && echo "$len" > "$OUTAGE_LEN"
      rm -f "$OB_SINCE"
      echo "outage ended after ''${len}s; starting ${toString wake.stableMinutes}m stability buffer"
      echo "$now" > "$OL_SINCE"
      exit 0
    fi

    # Guard 1: no witnessed outage means nothing to do.
    [ -f "$OUTAGE_LEN" ] || exit 0

    # Guard 2: too short for anything to have shed.
    if [ "$(cat "$OUTAGE_LEN")" -lt ${toString (wake.minOutageMinutes * 60)} ]; then
      echo "outage was only $(cat "$OUTAGE_LEN")s — nothing would have shed; forgetting"
      rm -f "$OUTAGE_LEN" "$OL_SINCE" $STATE/attempts-*
      exit 0
    fi

    # Guard 3: the anti-flap buffer.
    [ -f "$OL_SINCE" ] || echo "$now" > "$OL_SINCE"
    stable=$(( now - $(cat "$OL_SINCE") ))
    if [ "$stable" -lt ${toString (wake.stableMinutes * 60)} ]; then
      echo "mains stable for ''${stable}s, waiting for ${toString (wake.stableMinutes * 60)}s"
      exit 0
    fi

    pending=0
    ${lib.concatMapStringsSep "\n" (t: ''
      # ---- ${t.name} ----
      ATT=$STATE/attempts-${t.name}
      LAST=$STATE/last-attempt-${t.name}
      if ping -c1 -W2 ${t.ip} >/dev/null 2>&1; then
        if [ -f "$ATT" ]; then
          echo "${t.name} is back"
          notify "UPS: ${t.name} is back" 3 white_check_mark \
            "${t.name} answered after $(cat "$ATT") wake attempt(s) following the outage."
          rm -f "$ATT" "$LAST"
        fi
      else
        n=$(cat "$ATT" 2>/dev/null || echo 0)
        since_last=$(( now - $(cat "$LAST" 2>/dev/null || echo 0) ))
        if [ "$n" -ge ${toString wake.maxAttempts} ]; then
          if [ -f "$ATT" ]; then
            echo "${t.name} did not come back after $n attempts"
            notify "UPS: could not wake ${t.name}" 5 warning \
              "${t.name} did not answer after $n magic packets. Most likely the battery ran flat, so the NIC lost standby power and its WoL arming with it — that case needs the BIOS *Restore on AC Power Loss* setting or a physical press."
            rm -f "$ATT" "$LAST"
          fi
        elif [ "$since_last" -ge ${toString (wake.retrySeconds)} ]; then
          n=$(( n + 1 ))
          echo "$n" > "$ATT"; echo "$now" > "$LAST"
          echo "sending magic packet to ${t.name} (attempt $n)"
          wakeonlan -i ${wake.broadcast} ${t.mac} || true
          notify "UPS: waking ${t.name}" 4 electric_plug \
            "Mains has been stable for $(( stable / 60 ))m after a $(( $(cat "$OUTAGE_LEN") / 60 ))m outage; sent a magic packet to ${t.name} (attempt $n/${toString wake.maxAttempts})."
          pending=1
        else
          pending=1
        fi
      fi
    '') wake.targets}

    # Only forget the outage once nothing is still being chased, so a retry
    # sequence survives across ticks.
    if [ "$pending" = "0" ]; then
      rm -f "$OUTAGE_LEN" "$OL_SINCE"
    fi
  '';
in

{
  options.homelab.ups.remoteShutdown = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Power off machines that cannot run upsmon themselves, over SSH, while the
        UPS still has charge. Intended for appliances — erebor's UniFi OS has no
        NUT client, so without this its Btrfs array is cut mid-write every
        outage.
      '';
    };
    afterMinutes = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Trigger after this many continuous minutes on battery.";
    };
    belowCharge = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        Trigger once battery charge is at or below this percentage. Preferred over
        `afterMinutes` for an array: it is a direct measure of how much margin is
        left, and must stay comfortably above `battery.charge.low` so the disks
        finish flushing before anything else starts shutting down.
      '';
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Private SSH key used to reach the targets. A dedicated key, not a host
        key — same pattern as nix_remote_builder_key.
      '';
    };
    unmountFirst = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Local mount points served by the targets, lazily unmounted before they
        are powered off. Without this, THIS host keeps `hard` NFS mounts to a
        machine that has vanished and blocks forever in D state. Lazy so open
        file handles (Music Assistant, restic) cannot veto the sequence.
      '';
    };
    waitForDown = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Addresses of OTHER hosts that mount the targets. They must be down first,
        or powering the target off hangs them on `hard` NFS and stalls their own
        shutdown. Bounded by `waitMinutes`.
      '';
    };
    waitMinutes = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        How long to wait for `waitForDown` hosts before proceeding regardless. A
        consumer that never sheds must not deadlock this and leave the array to
        be cut anyway — a hung client on a host minutes from shutdown is the
        lesser problem, and the override is announced.
      '';
    };
    targets = lib.mkOption {
      default = [ ];
      description = "Machines to power off. Adding one is adding an entry here.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Name used in logs and notifications.";
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "Address to SSH to. An IP: DNS may be down.";
            };
            user = lib.mkOption {
              type = lib.types.str;
              default = "root";
              description = "SSH user; must be able to run poweroff.";
            };
          };
        }
      );
    };
  };

  options.homelab.ups.wakeOnRestore = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Send Wake-on-LAN packets to hosts that shed themselves during an outage,
        once mains power has been stably restored. Only ever fires after an
        outage this host observed.
      '';
    };
    stableMinutes = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = ''
        How long mains must be continuously present before any packet is sent.
        Anti-flap buffer: any return to battery restarts this clock, so a utility
        bouncing power while it restores does not spend wake attempts or wake a
        host into the next brownout.
      '';
    };
    minOutageMinutes = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        Ignore outages shorter than this. Should be at least the smallest
        `homelab.ups.shedAfterMinutes` among the targets: below it nothing would
        have shed, so an unreachable host is down for some unrelated reason and
        must not be woken.
      '';
    };
    maxAttempts = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "Magic packets to send before reporting failure and giving up.";
    };
    retrySeconds = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = ''
        Gap between attempts. Must comfortably exceed the target's POST-to-ping
        time, or the retry fires while the host is already booting.
      '';
    };
    broadcast = lib.mkOption {
      type = lib.types.str;
      default = "10.0.1.255";
      description = ''
        Broadcast address to send to. Must be the target's own subnet broadcast —
        255.255.255.255 stays on the default VLAN, the same trap documented for
        the IoT VLAN in hosts/rivendell.nix.
      '';
    };
    targets = lib.mkOption {
      default = [ ];
      description = "Hosts to wake. Adding one is adding an entry here.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Host name, used in log lines and notifications.";
            };
            mac = lib.mkOption {
              type = lib.types.str;
              description = "MAC of the target's WoL-armed interface.";
            };
            ip = lib.mkOption {
              type = lib.types.str;
              description = "Address pinged to decide whether the target is back.";
            };
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf rsd.enable {
      systemd.services.homelab-ups-remote-shutdown = {
        description = "Power off UPS-blind machines while charge remains";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${shutdownScript}";
          StateDirectory = "homelab-ups-remote-shutdown";
        };
      };

      systemd.timers.homelab-ups-remote-shutdown = {
        description = "Poll UPS state to cleanly power off UPS-blind machines";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "30s";
          AccuracySec = "5s";
          Unit = "homelab-ups-remote-shutdown.service";
        };
      };
    })

    (lib.mkIf wake.enable {
      systemd.services.homelab-ups-wake = {
        description = "Wake hosts shed during a power outage";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${wakeScript}";
          StateDirectory = "homelab-ups-wake";
        };
      };

      systemd.timers.homelab-ups-wake = {
        description = "Poll UPS state to wake shed hosts once mains is stable";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "30s";
          AccuracySec = "10s";
          Unit = "homelab-ups-wake.service";
        };
      };
    })

    {
  power.ups = {
    enable = true;
    mode = "netserver";

    ups.tripplite = {
      driver = "usbhid-ups";
      port = "auto";
      description = "Tripp Lite SMC15002URM";
      directives = [
        "vendorid = 09AE"
        "productid = 3015"
      ];
    };

    upsd = {
      listen = [{ address = "0.0.0.0"; port = 3493; }];
    };

    users = {
      # Internal user for upsmon to authenticate with upsd
      upsmon = {
        passwordFile = config.sops.secrets.nut_upsmon_password.path;
        upsmon = "primary";
      };
      # Account the secondaries authenticate as (modules/nut-secondary.nix on
      # mirkwood, pirateship and orthanc).
      #
      # Deliberately NOT the `upsmon` user above. That one is declared
      # `upsmon = "primary"`, which in upsd.users grants the privileged set —
      # including FSD, the command that tells every other host to shut down.
      # Handing that to three remote clients would mean any one of them could
      # power down the whole lab. `upsmon = "secondary"` grants only the
      # read-and-listen access a secondary actually needs.
      #
      # Same split-by-privilege reasoning as nut_upsmon_password vs
      # nut_ha_password, and as github_runner_token vs gatus_github_token.
      #
      # The password must match nut_secondary_password in each secondary's own
      # secrets file — four copies of one value, since sops-nix renders per host.
      upsmon-secondary = {
        passwordFile = config.sops.secrets.nut_secondary_password.path;
        upsmon = "secondary";
      };

      # User for Home Assistant NUT integration
      homeassistant = {
        passwordFile = config.sops.secrets.nut_ha_password.path;
      };
    };

    upsmon = {
      monitor.tripplite = {
        system = "tripplite@localhost";
        powerValue = 1;
        user = "upsmon";
        passwordFile = config.sops.secrets.nut_upsmon_password.path;
        type = "primary";
      };

      settings = {
        NOTIFYCMD = "${nutNotify}";
        NOTIFYFLAG = [
          ["ONBATT"   "SYSLOG+EXEC"]
          ["LOWBATT"  "SYSLOG+EXEC"]
          ["ONLINE"   "SYSLOG+EXEC"]
          ["COMMBAD"  "SYSLOG+EXEC"]
          ["COMMOK"   "SYSLOG+EXEC"]
          ["SHUTDOWN" "SYSLOG+EXEC"]
        ];
      };
    };
  };

  networking.firewall.allowedTCPPorts = [ 3493 ];

  # ---------------------------------------------------------------------------
  # Prometheus exporter
  #
  # Until 2026-08-01 the UPS was visible only to Home Assistant and to upsmon's
  # NOTIFYCMD pushes. Nothing recorded battery charge, load, or input voltage
  # over time, so "the UPS has been running hot for a month" or "runtime is half
  # what it was a year ago" were unanswerable. This feeds the UPS alert rules in
  # modules/grafana.nix.
  #
  # Deliberately reuses the existing read-only `homeassistant` monitor account
  # rather than adding a third NUT user: it already has exactly the access an
  # exporter needs (read variables, no instcmds), and a new user would mean a new
  # sops secret for no additional isolation. Both consumers are read-only and
  # local, so a shared credential costs nothing here. If that ever stops being
  # true, add a dedicated `prometheus` user with its own nut_prom_password.
  services.prometheus.exporters.nut = {
    enable = true;
    port = 9199;
    nutServer = "127.0.0.1";
    nutUser = "homeassistant";
    passwordPath = config.sops.secrets.nut_ha_password.path;
    openFirewall = true;
  };

  # The exporter reads the password file directly (`NUT_EXPORTER_PASSWORD=$(cat
  # …)` in its ExecStart) and runs under DynamicUser, so it needs group access
  # to the sops-rendered secret. The matching mode/group is set on the secret in
  # hosts/rivendell.nix.
  users.groups.nut-monitor = {};
  systemd.services.prometheus-nut-exporter.serviceConfig.SupplementaryGroups =
    [ config.users.groups.nut-monitor.name ];

      homelab.postUpgradeCheck.services = [ "upsd" "upsmon" ];
    }
  ];
}
