"""Merge declared settings into a standalone emulator's own config files.

Run by the wrappers in modules/emulation.nix immediately before the emulator
starts, with one argument: a JSON spec, a list of

    {"format": "ini" | "qtini" | "xml" | "toml",
     "path":   "/home/brian/.config/...",
     "set":    {...},   # written on every launch
     "seed":   {...}}   # written only where the key is absent

Shape of "set"/"seed" per format:
    ini, qtini  {"Section": {"Key": "value"}}
    xml         {"Graphic/api": "1"}   (paths below the root element)
    toml        nested tables, e.g. {"display": {"window": {...}}}

Only the named keys are touched; everything else in the file — including what
the emulator's own UI wrote — is preserved. A missing file is created. qtini
is ini plus Qt's QSettings convention: each key has a `key\\default` twin,
and a value the emulator still believes is default is replaced by its built-in
default on save, so `key\\default=false` is written alongside it.

Never fails the launch: a config this script cannot parse is left alone and
reported on stderr, because an emulator that starts with its own settings
beats one that does not start.
"""

import configparser
import json
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from io import StringIO

import tomlkit


def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".merge-")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def merge_ini(entry, qt):
    parser = configparser.RawConfigParser(strict=False, delimiters=("=",))
    parser.optionxform = str  # keys are case-sensitive in every emulator here
    if os.path.exists(entry["path"]):
        parser.read(entry["path"], encoding="utf-8")

    def put(section, key, value, only_if_absent):
        if not parser.has_section(section):
            parser.add_section(section)
        if only_if_absent and parser.has_option(section, key):
            # Qt writes every key on first save; one still marked as its
            # built-in default was never chosen, so a seed may claim it.
            if not (qt and parser.get(section, key + "\\default",
                                      fallback="false") == "true"):
                return
        parser.set(section, key, str(value))
        if qt:
            parser.set(section, key + "\\default", "false")

    for section, keys in entry.get("seed", {}).items():
        for key, value in keys.items():
            put(section, key, value, True)
    for section, keys in entry.get("set", {}).items():
        for key, value in keys.items():
            put(section, key, value, False)

    out = StringIO()
    # Qt's QSettings writes `key=value`; Dolphin and PCSX2 write `key = value`
    # and read either.
    parser.write(out, space_around_delimiters=not qt)
    atomic_write(entry["path"], out.getvalue())


def merge_xml(entry):
    if os.path.exists(entry["path"]):
        tree = ET.parse(entry["path"])
        root = tree.getroot()
    else:
        root = ET.Element(entry["root"])
        tree = ET.ElementTree(root)

    def put(path, value, only_if_absent):
        node = root
        for part in path.split("/"):
            child = node.find(part)
            if child is None:
                child = ET.SubElement(node, part)
            node = child
        if only_if_absent and node.text:
            return
        node.text = str(value)

    for path, value in entry.get("seed", {}).items():
        put(path, value, True)
    for path, value in entry.get("set", {}).items():
        put(path, value, False)

    ET.indent(tree)
    atomic_write(entry["path"],
                 '<?xml version="1.0" encoding="UTF-8"?>\n'
                 + ET.tostring(root, encoding="unicode") + "\n")


def merge_toml(entry):
    doc = tomlkit.document()
    if os.path.exists(entry["path"]):
        with open(entry["path"], encoding="utf-8") as f:
            doc = tomlkit.parse(f.read())

    def put(table, values, only_if_absent):
        for key, value in values.items():
            if isinstance(value, dict):
                if key not in table:
                    table[key] = tomlkit.table()
                put(table[key], value, only_if_absent)
            elif not (only_if_absent and key in table):
                table[key] = value

    put(doc, entry.get("seed", {}), True)
    put(doc, entry.get("set", {}), False)
    atomic_write(entry["path"], tomlkit.dumps(doc))


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        spec = json.load(f)
    for entry in spec:
        try:
            fmt = entry["format"]
            if fmt in ("ini", "qtini"):
                merge_ini(entry, qt=(fmt == "qtini"))
            elif fmt == "xml":
                merge_xml(entry)
            elif fmt == "toml":
                merge_toml(entry)
            else:
                raise ValueError(f"unknown format {fmt!r}")
        except Exception as e:  # noqa: BLE001 — see the docstring
            print(f"emulation-config-merge: {entry.get('path')}: {e}; "
                  "left unchanged", file=sys.stderr)


if __name__ == "__main__":
    main()
