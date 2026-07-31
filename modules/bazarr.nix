# modules/bazarr.nix — Bazarr subtitle manager
#
# Companion to Radarr/Sonarr: monitors the media library for missing subtitles
# and downloads them from configured providers (OpenSubtitles.com, etc.).
#
# Runs as the `brian` user (uid 1000) to match the PUID=1000 used by the arr
# containers, ensuring it can read/write subtitle files on the erebor NFS mount.
#
# Bazarr keeps all of its configuration in /var/lib/bazarr (config.yaml + a
# SQLite DB) and rewrites both at runtime, so none of it can be expressed in
# Nix — it is set through the web UI or the REST API. Documented here so the
# settings that matter are recoverable.
#
# One-time web UI setup required after first deploy:
#   1. Open subtitles.theshire.io → Settings → Sonarr
#      - Host: localhost, Port: 8989, API key from Sonarr UI
#   2. Settings → Radarr
#      - Host: localhost, Port: 7878, API key from Radarr UI
#   3. Settings → Providers → add OpenSubtitles.com (free account required)
#   4. Settings → Languages → create an "English" profile (en, non-forced)
#   5. Settings → Sonarr/Radarr → enable "Default Language Profile" and point
#      both at that profile. Without this, newly added series and movies get no
#      language profile at all and Bazarr silently never searches for them.
#
# PATH MAPPINGS — the sharp edge.
#
# Sonarr and Radarr run as containers with /var/lib/media bind-mounted at
# /media (see arr-stack.nix), so their root folders are /media/tv and
# /media/movies. Bazarr runs natively on the host and sees /var/lib/media, so
# Settings → Sonarr/Radarr → Path Mappings must translate between them:
#
#   Sonarr: /media/tv/     → /var/lib/media/tv/
#   Radarr: /media/movies/ → /var/lib/media/movies/
#
# Bazarr applies these as a *substring* replacement, not a prefix match, so a
# stale mapping corrupts paths instead of failing loudly. When the containers
# moved from per-category mounts (/tv, /movies) to a single /media mount in
# 386c764, the old /tv/ → /var/lib/media/tv/ mapping turned "/media/tv/Show"
# into "/media/var/lib/media/tv/Show" — a path that does not exist. Bazarr
# logged no errors, reported 0 missing subtitles, and quietly downloaded
# nothing for four months.
#
# If the arr container mounts or root folders ever change again, update these
# mappings in the same commit, then verify with:
#   curl -s -H "X-API-KEY: $KEY" localhost:6767/api/movies?length=3 | jq -r .data[].path
# and confirm the returned paths actually exist on the host.

{ ... }:

{
  services.bazarr = {
    enable = true;
    # Run as brian (uid 1000) to match arr container PUID — required for NFS write access
    user = "brian";
    group = "users";
    listenPort = 6767;
    openFirewall = true;
  };
}
