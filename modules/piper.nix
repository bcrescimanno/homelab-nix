# modules/piper.nix — local text-to-speech for Home Assistant (rivendell)
#
# Piper, served over the Wyoming protocol, replaces Google Translate as the
# voice for announcements. It runs entirely on this host: no cloud round-trip,
# and nothing to lose when the internet is down.
#
# Announcements reach the HomePods through Music Assistant, not through the
# HomePods' own Siri voice — AirPlay only carries audio, and Apple exposes no
# API for Intercom. `tts.speak` sets `announce: true`, which MA turns into
# players/cmd/play_announcement on the AirPlay player.
#
# Bound to loopback with zeroconf off: HA is the only client and lives on this
# host. The one imperative step is adding the integration once in the HA UI —
# Settings → Devices & services → Add Integration → Wyoming Protocol, host
# 127.0.0.1, port 10200. Wyoming has no YAML setup, so this cannot be declared.
#
# `voice` is only the default. A single server speaks any Piper voice, passed
# per call as `options: { voice: ..., speaker: ... }`, and downloads each model
# on first use into /var/lib/private/wyoming/piper (DynamicUser, so that is the
# real path). Samples: https://rhasspy.github.io/piper-samples/
#
# STATUS: NOT DECIDED — do not merge or deploy as-is. The default voice below is
# a placeholder until the shortlist has had more listening tests on the
# HomePods (2026-09-13). Wanted: an English- or Australian-sounding male voice.
# Piper has NO en_AU voice; the only candidates are en_GB models.
#
# Shortlist, after two rounds on the Kitchen HomePod:
#   1. Alan                  en_GB-alan-medium
#   2. Northern English Male en_GB-northern_english_male-medium
#   3. VCTK p232 (S England) en_GB-vctk-medium  speaker 60
#   4. VCTK p227 (Cumbria)   en_GB-vctk-medium  speaker 82
#   5. ARU 02                en_GB-aru-medium   speaker 9  (accent unrecorded)
# Rejected: every female voice; Ryan (US); VCTK p243 London, p226 Surrey,
# p256 Birmingham, p274 Essex; Semaine Obadiah/Spike; VCTK p326/p374 (the
# possible Australians).
#
# Speaker numbers are Piper's integer ids from the model's speaker_id_map, not
# the pNNN names. The VCTK map was checked against the corpus metadata by
# pitch: all 25 labelled women measured 119-178 Hz and all 24 labelled men
# 62-110 Hz, so the published gender/accent labels do line up in this model.
#
# Once a voice is chosen: set `voice` (and `speaker` for a multi-speaker
# model), deploy, add the Wyoming integration in the UI, and send a test
# through HA's own `tts.speak` — the auditions so far went straight to Music
# Assistant and never exercised the HA → Wyoming leg.

{ ... }:

{
  services.wyoming.piper.servers.announce = {
    enable = true;
    voice = "en_GB-alan-medium"; # placeholder — see STATUS above
    uri = "tcp://127.0.0.1:10200";
    zeroconf.enable = false;
  };
}
