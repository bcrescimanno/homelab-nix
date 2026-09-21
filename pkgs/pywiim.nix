# pkgs/pywiim.nix — WiiM/LinkPlay client library, required by Music Assistant's
# wiim provider since MA 2.10 and not yet in nixpkgs.
#
# Called with MA's own python package set (see modules/music-assistant.nix), so
# it resolves against exactly the aiohttp/pydantic MA runs with.
#
# The version tracks the `pywiim==` pin in MA's
# music_assistant/providers/wiim/manifest.json. nixpkgs strips MA's version
# check, so a drifted pin is not an error at startup -- it surfaces as the wiim
# provider failing to load again. Re-read the manifest when MA bumps.
{ buildPythonPackage, fetchPypi, setuptools, wheel
, aiohttp, pydantic, async-upnp-client, m3u8, mutagen }:

buildPythonPackage rec {
  pname = "pywiim";
  version = "2.3.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-/SOxSvddmVgqpAgnE5HdGHuVD/JYVbQA9/4Wngmbkr0=";
  };

  build-system = [ setuptools wheel ];

  dependencies = [ aiohttp pydantic async-upnp-client m3u8 mutagen ];

  # The sdist ships no tests; importing what MA imports is the gate.
  pythonImportsCheck = [ "pywiim" "pywiim.model_names" ];
}
