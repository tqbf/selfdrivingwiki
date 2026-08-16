#!/usr/bin/env python3
"""Verify — and where possible repair — this machine's code-signing setup.

`make build` runs this first. The common case is the fast path: three
provisioning profiles are on disk, they cover this Mac, and it exits in about
a fifth of a second having touched the network zero times.

When a check fails it repairs, because the failure modes are silent and
expensive. A profile that omits your Mac still signs; the app then dies at
launch under AMFI with no crash report. A daemon signed without its keychain
entitlement starts fine and reads back empty credentials at ingest time.

The repair rules that matter:

  * **Profiles carry every Mac and every certificate.** One developer with two
    laptops needs one profile set that covers both. Regenerating per-machine
    (what `setup.sh` used to do) hands laptop A a working build by taking
    laptop B out of the profile, which is a loop with no exit.
  * **Create before delete.** A new profile is downloaded and verified before
    the profile it replaces is removed, so a failure halfway through leaves the
    old, working set intact.
  * **Never break the build.** Missing `asc`, no Apple account, no config: say
    what is degraded and exit 0. `build.sh` falls back to ad-hoc signing.

The one thing this cannot do is create an App Group and bind it to a bundle
id — App Store Connect has no API for it. That step is printed as exact
portal instructions.

See plans/signing-preflight.md.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SIGNING_DIR = REPO_ROOT / "signing"
CONFIG_PATH = SIGNING_DIR / "local.config"

# Records the bundle ids waiting on the portal-only App Group binding. Without
# it, every `make` would re-attempt a repair that cannot succeed until a human
# visits developer.apple.com — six API calls and a created-then-deleted profile
# per build. `make signing-repair` ignores this file; it is only a brake on the
# automatic path.
PENDING_PATH = SIGNING_DIR / ".portal-pending"
PORTAL_RETRY = dt.timedelta(hours=6)

# Regenerate a profile once it is inside this window of expiry, so a laptop
# picked up after a month away is not signing with a profile that dies mid-week.
RENEW_MARGIN = dt.timedelta(days=30)

PROFILE_TYPE = "MAC_APP_DEVELOPMENT"


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

_QUIET = False


def say(msg: str = "") -> None:
    if not _QUIET:
        print(msg)


def ok(msg: str) -> None:
    say(f"  \033[1;32m✓\033[0m {msg}")


def info(msg: str) -> None:
    say(f"  \033[1;34m→\033[0m {msg}")


def warn(msg: str) -> None:
    say(f"  \033[1;33m!\033[0m {msg}")


def bad(msg: str) -> None:
    say(f"  \033[1;31m✗\033[0m {msg}")


# --------------------------------------------------------------------------
# signing/local.config
# --------------------------------------------------------------------------

CONFIG_HEADER = """\
# signing/local.config — per-developer signing identifiers (gitignored).
#
# Sourced by build.sh, parsed by the Makefile, and read at runtime by
# WikiIdentifiers. Written by signing/preflight.py and signing/setup.sh; safe
# to hand-edit. Shell syntax: KEY="value", no spaces around '='.
"""


def read_config() -> dict[str, str]:
    """Parse the shell-syntax config into a dict (missing file → empty)."""
    values: dict[str, str] = {}
    if not CONFIG_PATH.exists():
        return values
    for raw in CONFIG_PATH.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    return values


def write_config(updates: dict[str, str]) -> list[str]:
    """Merge `updates` into the config, preserving comments and hand edits.

    Only keys whose value actually changes are rewritten. Returns the names of
    the keys that were added or changed, for reporting.
    """
    existing = read_config()
    changed = [k for k, v in updates.items() if existing.get(k) != v and v]
    if not changed:
        return []

    if CONFIG_PATH.exists():
        lines = CONFIG_PATH.read_text().splitlines()
    else:
        lines = CONFIG_HEADER.splitlines()

    out: list[str] = []
    seen: set[str] = set()
    for line in lines:
        match = re.match(r"^\s*([A-Z_][A-Z0-9_]*)\s*=", line)
        key = match.group(1) if match else None
        if key and key in updates and updates[key]:
            seen.add(key)
            out.append(f'{key}="{updates[key]}"')
        else:
            out.append(line)

    appended = [k for k in updates if k not in seen and updates[k]]
    if appended:
        out.append("")
        for key in appended:
            out.append(f'{key}="{updates[key]}"')

    CONFIG_PATH.write_text("\n".join(out) + "\n")
    return changed


# --------------------------------------------------------------------------
# Machine facts
# --------------------------------------------------------------------------


def provisioning_udid() -> str:
    """This Mac's Provisioning UDID — the id the Apple portal registers Macs by.

    Deliberately not the Hardware UUID that `ioreg` (and `asc devices
    local-udid`) report: the portal rejects that one for Macs. See
    plans/signing.md.
    """
    try:
        out = subprocess.run(
            ["system_profiler", "SPHardwareDataType"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    match = re.search(r"Provisioning UDID:\s*(\S+)", out)
    return match.group(1) if match else ""


def keychain_identities() -> list[tuple[str, str]]:
    """`(sha1, display name)` for every valid codesigning identity locally."""
    try:
        out = subprocess.run(
            ["security", "find-identity", "-v", "-p", "codesigning"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [(m.group(1).upper(), m.group(2))
            for m in re.finditer(r"\)\s+([0-9A-Fa-f]{40})\s+\"(.*)\"", out)]


def computer_name() -> str:
    try:
        name = subprocess.run(
            ["scutil", "--get", "ComputerName"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        return name or "My Mac"
    except (OSError, subprocess.SubprocessError):
        return "My Mac"


# --------------------------------------------------------------------------
# Provisioning profiles
# --------------------------------------------------------------------------


@dataclass
class Profile:
    """The facts we care about from a decoded `.provisionprofile`."""

    name: str
    uuid: str
    expires: dt.datetime | None
    team: str
    app_id: str                     # entitlement `application-identifier`
    devices: list[str]
    app_groups: list[str]
    keychain_groups: list[str]
    cert_sha1s: list[str]

    @classmethod
    def decode(cls, path: Path) -> "Profile | None":
        """Decode a CMS-signed profile, or None if unreadable."""
        try:
            raw = subprocess.run(
                ["security", "cms", "-D", "-i", str(path)],
                capture_output=True, timeout=30,
            ).stdout
            data = plistlib.loads(raw)
        except Exception:
            return None
        ent = data.get("Entitlements", {}) or {}
        # macOS profiles spell it `com.apple.application-identifier`; iOS
        # profiles use the bare `application-identifier`. Accept either.
        app_id = (ent.get("com.apple.application-identifier")
                  or ent.get("application-identifier", ""))
        expires = data.get("ExpirationDate")
        if isinstance(expires, dt.datetime) and expires.tzinfo is None:
            expires = expires.replace(tzinfo=dt.timezone.utc)
        return cls(
            name=data.get("Name", ""),
            uuid=data.get("UUID", ""),
            expires=expires,
            team=(data.get("TeamIdentifier") or [""])[0],
            app_id=app_id,
            devices=list(data.get("ProvisionedDevices") or []),
            app_groups=list(ent.get("com.apple.security.application-groups") or []),
            keychain_groups=list(ent.get("keychain-access-groups") or []),
            cert_sha1s=[hashlib.sha1(c).hexdigest().upper()
                        for c in (data.get("DeveloperCertificates") or [])],
        )


def authorizes(value: str, granted: list[str]) -> bool:
    """Whether `value` is covered by a profile's entitlement list.

    Apple auto-adds a `<TEAM_ID>.*` wildcard alongside the explicit grants, so
    a plain membership test is not enough — but the wildcard does NOT cover a
    `group.`-prefixed App Group, which is why an unbound App Group still fails
    here. That distinction is the whole point of this function.
    """
    for entry in granted:
        if entry == value:
            return True
        if entry.endswith("*") and value.startswith(entry[:-1]):
            return True
    return False


# --------------------------------------------------------------------------
# App Store Connect (`asc`)
# --------------------------------------------------------------------------


class AscError(RuntimeError):
    pass


class Asc:
    """Thin wrapper over the `asc` CLI. Every call here hits Apple's API."""

    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run
        # Listings are re-read several times across a repair (once per slot).
        # Cache them and drop the cache after anything that mutates, so a
        # three-slot repair costs three GETs rather than a dozen.
        self._cache: dict[str, list[dict]] = {}

    @staticmethod
    def available() -> bool:
        if shutil.which("asc") is None:
            return False
        try:
            return subprocess.run(
                ["asc", "auth", "status"],
                capture_output=True, timeout=60,
            ).returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def _run(self, args: list[str], mutating: bool) -> dict:
        if mutating and self.dry_run:
            say(f"    [dry-run] asc {' '.join(args)}")
            return {}
        proc = subprocess.run(
            ["asc", *args, "--output", "json"],
            capture_output=True, text=True, timeout=180,
        )
        if proc.returncode != 0:
            message = (proc.stderr or proc.stdout).strip()
            raise AscError(message.splitlines()[0] if message else "asc failed")
        try:
            return json.loads(proc.stdout or "{}")
        except json.JSONDecodeError:
            return {}

    def get(self, args: list[str]) -> dict:
        return self._run(args, mutating=False)

    def mutate(self, args: list[str]) -> dict:
        result = self._run(args, mutating=True)
        self._cache.clear()
        return result

    def _listing(self, key: str, args: list[str]) -> list[dict]:
        if key not in self._cache:
            self._cache[key] = self.get(args).get("data", [])
        return self._cache[key]

    # -- resources ---------------------------------------------------------

    def bundle_ids(self) -> list[dict]:
        return self._listing("bundle-ids", ["bundle-ids", "list"])

    def devices(self) -> list[dict]:
        return self._listing("devices", ["devices", "list"])

    def certificates(self) -> list[dict]:
        return self._listing("certificates", ["certificates", "list"])

    def profiles(self) -> list[dict]:
        return self._listing("profiles", ["profiles", "list"])

    def profiles_for_bundle(self, bundle_res: str) -> list[dict]:
        try:
            return self._listing(f"profiles:{bundle_res}",
                                 ["bundle-ids", "profiles", "list", "--id", bundle_res])
        except AscError:
            return []

    def download_profile(self, profile_id: str, dest: Path) -> None:
        proc = subprocess.run(
            ["asc", "profiles", "download", "--id", profile_id, "--output", str(dest)],
            capture_output=True, text=True, timeout=120,
        )
        if proc.returncode != 0:
            raise AscError((proc.stderr or proc.stdout).strip())


# --------------------------------------------------------------------------
# Slots — the three bundles that need a profile
# --------------------------------------------------------------------------


@dataclass
class Slot:
    key: str
    filename: str
    profile_name: str          # canonical name in the developer portal
    display: str               # bundle id display name when creating it
    needs_keychain: bool       # daemon + app share the keychain access group
    bundle_id: str = ""
    problems: list[str] = field(default_factory=list)

    @property
    def path(self) -> Path:
        return SIGNING_DIR / self.filename


def slots_for(cfg: dict[str, str]) -> list[Slot]:
    """The three bundles that need a profile, with their ids resolved.

    The extension and daemon ids are derived from the app id when the config
    does not name them, using exactly the derivations in `build.sh` — the
    entitlement and the profile have to agree on the same string or AMFI
    rejects the signature.
    """
    app_id = cfg.get("BUNDLE_ID", "")
    ext_id = cfg.get("EXT_BUNDLE_ID") or (f"{app_id}.FileProvider" if app_id else "")
    daemon_id = cfg.get("DAEMON_BUNDLE_ID") or (f"{app_id}.wikid" if app_id else "")
    return [
        Slot("app", "WikiFS.provisionprofile", "Self Driving Wiki Dev",
             "Self Driving Wiki", needs_keychain=True, bundle_id=app_id),
        Slot("ext", "WikiFSFileProvider.provisionprofile",
             "Self Driving Wiki FileProvider Dev",
             "Self Driving Wiki File Provider", needs_keychain=False,
             bundle_id=ext_id),
        Slot("daemon", "wikid.provisionprofile", "Self Driving Wiki Daemon Dev",
             "Self Driving Wiki Daemon", needs_keychain=True, bundle_id=daemon_id),
    ]


def keychain_group(cfg: dict[str, str]) -> str:
    """`<TEAM_ID>.<app group minus its "group." prefix>` — build.sh's formula."""
    explicit = cfg.get("KEYCHAIN_ACCESS_GROUP")
    if explicit:
        return explicit
    group = cfg.get("APP_GROUP", "")
    return f"{cfg.get('TEAM_ID', '')}.{group[len('group.'):] if group.startswith('group.') else group}"


# --------------------------------------------------------------------------
# Health check (offline)
# --------------------------------------------------------------------------


def check_slot(slot: Slot, cfg: dict[str, str], udid: str,
               local_sha1s: set[str]) -> list[str]:
    """Everything wrong with this slot's profile, as human-readable strings."""
    problems: list[str] = []
    if not slot.bundle_id:
        return ["no bundle id configured"]
    if not slot.path.exists():
        return ["profile missing"]

    profile = Profile.decode(slot.path)
    if profile is None:
        return ["profile unreadable"]

    team = cfg.get("TEAM_ID", "")
    expected_app_id = f"{team}.{slot.bundle_id}"
    if profile.app_id != expected_app_id:
        problems.append(f"issued for {profile.app_id or '?'}, expected {expected_app_id}")
    if profile.expires is None:
        problems.append("no expiry date")
    else:
        remaining = profile.expires - dt.datetime.now(dt.timezone.utc)
        if remaining <= dt.timedelta(0):
            problems.append(f"expired {profile.expires:%Y-%m-%d}")
        elif remaining <= RENEW_MARGIN:
            problems.append(f"expires {profile.expires:%Y-%m-%d} ({remaining.days}d)")
    if udid and udid not in profile.devices:
        problems.append("does not cover this Mac")
    group = cfg.get("APP_GROUP", "")
    if group and not authorizes(group, profile.app_groups):
        problems.append(f"App Group {group} not authorized")
    if slot.needs_keychain:
        kc = keychain_group(cfg)
        if kc and not authorizes(kc, profile.keychain_groups):
            problems.append(f"keychain group {kc} not authorized")
    if local_sha1s and not (set(profile.cert_sha1s) & local_sha1s):
        problems.append("no matching certificate in this keychain")
    return problems


# --------------------------------------------------------------------------
# Bootstrap — infer config from the account (new laptop, same developer)
# --------------------------------------------------------------------------


def infer_config(asc: Asc, cfg: dict[str, str]) -> tuple[dict[str, str], list[str]]:
    """Fill in identifiers a fresh clone is missing, from the Apple account.

    `signing/local.config` is gitignored, so a second or third laptop starts
    with nothing. Everything in it is recoverable from the account, so infer
    rather than interrogate: find the `*.WikiFS` bundle id, take the team from
    its seed id, and read the App Group out of an existing profile (the API
    does not expose App Group bindings any other way).

    Returns the resolved config and any notes explaining what could not be
    inferred.
    """
    notes: list[str] = []
    resolved = dict(cfg)

    if not resolved.get("BUNDLE_ID"):
        candidates = [b for b in asc.bundle_ids()
                      if b["attributes"]["identifier"].endswith(".WikiFS")]
        if len(candidates) == 1:
            resolved["BUNDLE_ID"] = candidates[0]["attributes"]["identifier"]
            resolved.setdefault("TEAM_ID", candidates[0]["attributes"].get("seedId", ""))
            info(f"inferred BUNDLE_ID={resolved['BUNDLE_ID']} from your account")
        elif len(candidates) > 1:
            names = ", ".join(c["attributes"]["identifier"] for c in candidates)
            notes.append(f"several WikiFS bundle ids in the account ({names}) — "
                         "set BUNDLE_ID in signing/local.config or run signing/setup.sh")
            return resolved, notes
        else:
            notes.append("no WikiFS bundle ids in this account — "
                         "run ./signing/setup.sh --prefix com.yourname to provision them")
            return resolved, notes

    if not resolved.get("EXT_BUNDLE_ID"):
        resolved["EXT_BUNDLE_ID"] = resolved["BUNDLE_ID"] + ".FileProvider"
    if not resolved.get("DAEMON_BUNDLE_ID"):
        # Must match build.sh's derivation and WikiIdentifiers.daemonServiceID.
        resolved["DAEMON_BUNDLE_ID"] = resolved["BUNDLE_ID"] + ".wikid"

    if not resolved.get("TEAM_ID"):
        for b in asc.bundle_ids():
            if b["attributes"]["identifier"] == resolved["BUNDLE_ID"]:
                resolved["TEAM_ID"] = b["attributes"].get("seedId", "")

    if not resolved.get("APP_GROUP"):
        group = app_group_from_profiles(asc, resolved)
        if group:
            resolved["APP_GROUP"] = group
            info(f"inferred APP_GROUP={group} from an existing profile")
        else:
            notes.append("could not read the App Group from any existing profile — "
                         "set APP_GROUP in signing/local.config")

    if not resolved.get("DEV_IDENTITY"):
        for _, name in keychain_identities():
            if name.startswith("Apple Development:"):
                resolved["DEV_IDENTITY"] = name
                break
    if not resolved.get("DIST_IDENTITY"):
        for _, name in keychain_identities():
            if name.startswith("Developer ID Application:"):
                resolved["DIST_IDENTITY"] = name
                break

    return resolved, notes


def app_group_from_profiles(asc: Asc, cfg: dict[str, str]) -> str:
    """Read the App Group out of any existing profile for the app bundle id."""
    team = cfg.get("TEAM_ID", "")
    tmp = SIGNING_DIR / ".probe.provisionprofile"
    try:
        for entry in asc.profiles():
            attrs = entry["attributes"]
            if attrs.get("profileState") != "ACTIVE":
                continue
            try:
                asc.download_profile(entry["id"], tmp)
                profile = Profile.decode(tmp)
            except AscError:
                continue
            if profile is None or profile.app_id != f"{team}.{cfg.get('BUNDLE_ID','')}":
                continue
            for group in profile.app_groups:
                if group.startswith("group."):
                    return group
    finally:
        tmp.unlink(missing_ok=True)
    return ""


# --------------------------------------------------------------------------
# Repair
# --------------------------------------------------------------------------


@dataclass
class Repair:
    asc: Asc
    cfg: dict[str, str]
    udid: str
    local_sha1s: set[str]
    keep_old: bool = False
    portal_steps: list[str] = field(default_factory=list)

    def ensure_bundle_id(self, identifier: str, display: str) -> str:
        """Resource id for `identifier`, creating the App ID if it is absent."""
        for b in self.asc.bundle_ids():
            if b["attributes"]["identifier"] == identifier:
                return b["id"]
        info(f"creating App ID {identifier}")
        created = self.asc.mutate([
            "bundle-ids", "create", "--identifier", identifier,
            "--name", display, "--platform", "MAC_OS",
        ])
        res = (created.get("data") or {}).get("id", "")
        if res:
            # App Groups is the only capability we manage; binding the specific
            # group to it is portal-only (no API), handled further down.
            try:
                self.asc.mutate(["bundle-ids", "capabilities", "add",
                                 "--bundle", res, "--capability", "APP_GROUPS"])
            except AscError:
                pass                      # already enabled
        return res

    def ensure_device(self) -> None:
        """Register this Mac if the account has never seen it."""
        if not self.udid:
            return
        for d in self.asc.devices():
            if d["attributes"].get("udid") == self.udid:
                return
        info(f"registering this Mac ({self.udid})")
        self.asc.mutate([
            "devices", "register", "--name", computer_name(),
            "--platform", "MAC_OS", "--udid", self.udid,
        ])

    def macs(self) -> list[dict]:
        """Every enabled Mac in the account.

        The union is the point: a profile that lists only the machine that
        generated it is what makes two laptops fight over one profile set.
        """
        return [d for d in self.asc.devices()
                if d["attributes"].get("deviceClass") == "MAC"
                and d["attributes"].get("status") == "ENABLED"]

    def mac_device_ids(self) -> list[str]:
        return [d["id"] for d in self.macs()]

    def coverage_gap(self, slot: Slot) -> list[str]:
        """Registered Macs this slot's on-disk profile leaves out.

        Only meaningful once we are already talking to Apple, so it is not part
        of the offline check. Repairing it is what turns "works on the laptop
        that generated it" into one profile set that works on all of them.
        """
        profile = Profile.decode(slot.path) if slot.path.exists() else None
        if profile is None:
            return []
        known = {d["attributes"].get("udid", "") for d in self.macs()}
        return sorted(u for u in known if u and u not in profile.devices)

    def development_cert_ids(self) -> list[str]:
        """Every unexpired development certificate in the account.

        Also a union, for the same reason: each laptop holds a different
        private key, and a profile only validates a signature made with a
        certificate it lists.
        """
        now = dt.datetime.now(dt.timezone.utc)
        out = []
        for c in self.asc.certificates():
            attrs = c["attributes"]
            if attrs.get("certificateType") != "DEVELOPMENT":
                continue
            expiry = attrs.get("expirationDate")
            if expiry:
                try:
                    if dt.datetime.fromisoformat(expiry.replace("Z", "+00:00")) <= now:
                        continue
                except ValueError:
                    pass
            out.append(c["id"])
        return out

    def free_profile_name(self, base: str, taken: set[str]) -> str:
        if base not in taken:
            return base
        for n in range(2, 100):
            candidate = f"{base} {n}"
            if candidate not in taken:
                return candidate
        raise AscError(f"no free profile name for {base}")

    def repair_slot(self, slot: Slot, bundle_res: str,
                    devices: list[str], certs: list[str],
                    require_udids: list[str]) -> bool:
        """Give `slot` a profile that is valid on this machine. True if installed."""
        existing = self.asc.profiles_for_bundle(bundle_res)

        # An ACTIVE profile that already covers every registered Mac needs no
        # mutation at all — the second-laptop case, where the other machine has
        # already generated a profile carrying every device. Reusing it is why
        # a third laptop can come up without touching anyone else's setup.
        for entry in existing:
            if entry["attributes"].get("profileState") != "ACTIVE":
                continue
            if self.try_install(slot, entry["id"], require_udids):
                ok(f"{slot.key}: downloaded existing profile "
                   f"'{entry['attributes'].get('name')}'")
                return True

        if not devices or not certs:
            slot.problems.append("no registered Macs or development certificates")
            return False

        taken = {p["attributes"].get("name", "") for p in self.asc.profiles()}
        name = self.free_profile_name(slot.profile_name, taken)
        info(f"{slot.key}: creating profile '{name}' "
             f"({len(devices)} Mac(s), {len(certs)} cert(s))")
        created = self.asc.mutate([
            "profiles", "create", "--name", name,
            "--profile-type", PROFILE_TYPE,
            "--bundle", bundle_res,
            "--certificate", ",".join(certs),
            "--device", ",".join(devices),
        ])
        if self.asc.dry_run:
            for entry in existing:
                if entry["attributes"].get("name", "").startswith(slot.profile_name):
                    say(f"    [dry-run] asc profiles delete --id {entry['id']} "
                        f"--confirm   # '{entry['attributes'].get('name')}', "
                        "only after the replacement verifies")
            return False
        new_id = (created.get("data") or {}).get("id", "")
        if not new_id:
            slot.problems.append("profile creation returned no id")
            return False

        if not self.try_install(slot, new_id, require_udids):
            # The profile exists but does not authorize what we need — almost
            # always the App Group binding, which has no API. It is useless to
            # everyone, including a later run, so remove the thing we just made
            # rather than leaving litter behind.
            self.portal_steps.append(slot.bundle_id)
            try:
                self.asc.mutate(["profiles", "delete", "--id", new_id, "--confirm"])
            except AscError:
                pass
            return False

        ok(f"{slot.key}: installed {slot.filename}")
        # Only now that a verified replacement is on disk is it safe to remove
        # what it supersedes. Restricted to profiles for THIS bundle id whose
        # name we manage, so a hand-made profile is never collateral.
        if not self.keep_old:
            for entry in existing:
                attrs = entry["attributes"]
                if entry["id"] == new_id:
                    continue
                if not attrs.get("name", "").startswith(slot.profile_name):
                    continue
                try:
                    self.asc.mutate(["profiles", "delete", "--id", entry["id"], "--confirm"])
                    info(f"{slot.key}: removed superseded '{attrs.get('name')}'")
                except AscError:
                    pass
        return True

    def try_install(self, slot: Slot, profile_id: str,
                    require_udids: list[str]) -> bool:
        """Download a candidate profile and keep it only if it checks out.

        The candidate must pass the same check the fast path applies AND carry
        every Mac in `require_udids`. Verifying before the replace is what
        makes the repair safe to interrupt: the previous working profile stays
        in place until a better one is proven good.
        """
        tmp = slot.path.with_suffix(".provisionprofile.new")
        try:
            self.asc.download_profile(profile_id, tmp)
        except AscError:
            tmp.unlink(missing_ok=True)
            return False
        probe = Slot(slot.key, tmp.name, slot.profile_name, slot.display,
                     slot.needs_keychain, slot.bundle_id)
        decoded = Profile.decode(tmp)
        covers = decoded is not None and all(u in decoded.devices for u in require_udids)
        if check_slot(probe, self.cfg, self.udid, self.local_sha1s) or not covers:
            tmp.unlink(missing_ok=True)
            return False
        tmp.replace(slot.path)
        return True


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------


def read_pending() -> tuple[list[str], dt.datetime | None]:
    """Bundle ids blocked on the portal step, and when we last said so."""
    try:
        data = json.loads(PENDING_PATH.read_text())
        stamp = dt.datetime.fromisoformat(data["at"])
        return list(data.get("bundle_ids") or []), stamp
    except Exception:
        return [], None


def write_pending(bundle_ids: list[str]) -> None:
    PENDING_PATH.write_text(json.dumps({
        "bundle_ids": bundle_ids,
        "at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }, indent=2) + "\n")


def portal_instructions(cfg: dict[str, str], bundle_ids: list[str]) -> None:
    group = cfg.get("APP_GROUP", "group.example.wiki")
    say("")
    say("  ┌─ ONE MANUAL STEP — App Store Connect has no App Groups API ─────────────┐")
    say("  │ At https://developer.apple.com/account/resources/identifiers")
    say(f"  │   1. + → App Groups → Identifier: {group}")
    say("  │      (skip if it already exists)")
    for i, bid in enumerate(bundle_ids, start=2):
        say(f"  │   {i}. Open '{bid}' → App Groups → Edit → tick {group} → Save")
    say("  │ Then re-run: make signing-repair")
    say("  └─────────────────────────────────────────────────────────────────────────┘")


def run(args: argparse.Namespace) -> int:
    cfg = read_config()
    udid = provisioning_udid()
    identities = keychain_identities()
    local_sha1s = {sha for sha, _ in identities}

    slots = slots_for(cfg)
    problems = {s.key: check_slot(s, cfg, udid, local_sha1s) for s in slots}
    healthy = cfg.get("TEAM_ID") and not any(problems.values())

    if args.status or healthy:
        report(slots, problems, cfg, udid, identities, verbose=args.status)
        if healthy:
            PENDING_PATH.unlink(missing_ok=True)
            return 0
        if args.status:
            return 1

    if not args.repair and not args.check:
        return 1

    # A repair blocked on the portal cannot be un-blocked by trying again, so
    # on the automatic path back off rather than re-running it every build.
    if args.check and not args.repair:
        blocked, since = read_pending()
        if blocked and since and dt.datetime.now(dt.timezone.utc) - since < PORTAL_RETRY:
            unresolved = [s.key for s in slots
                          if problems[s.key] and s.bundle_id in blocked]
            if unresolved and all(not problems[s.key] or s.bundle_id in blocked
                                  for s in slots):
                warn(f"signing: {', '.join(unresolved)} still waiting on the App "
                     f"Group binding in the Apple portal — run 'make signing-repair' "
                     f"after doing it.")
                return 0

    # --- repair ---------------------------------------------------------
    say("→ signing preflight: repairing")
    for slot in slots:
        for p in problems[slot.key]:
            warn(f"{slot.key}: {p}")

    if not Asc.available():
        warn("asc is unavailable or not authenticated — skipping repair.")
        warn("The build continues with ad-hoc signing: no File Provider, no")
        warn("shared keychain. Install asc and run 'asc auth login', then")
        warn("'make signing-repair'. A fresh clone starts at ./signing/setup.sh.")
        return 0 if args.check else 1

    asc = Asc(dry_run=args.dry_run)
    try:
        cfg, notes = infer_config(asc, cfg)
        for note in notes:
            warn(note)
        if not cfg.get("BUNDLE_ID") or not cfg.get("TEAM_ID"):
            return 0 if args.check else 1
        if not cfg.get("APP_GROUP"):
            return 0 if args.check else 1

        slots = slots_for(cfg)
        repair = Repair(asc, cfg, udid, local_sha1s, keep_old=args.keep_old)
        repair.ensure_device()
        devices = repair.mac_device_ids()
        certs = repair.development_cert_ids()
        all_udids = [d["attributes"].get("udid", "") for d in repair.macs()]
        all_udids = [u for u in all_udids if u]

        for slot in slots:
            res = repair.ensure_bundle_id(slot.bundle_id, slot.display)
            if not res:
                warn(f"{slot.key}: no App ID for {slot.bundle_id}")
                continue
            reasons = list(problems[slot.key])
            # Already online, so also close the gap that makes multi-laptop
            # setups thrash: a profile valid here but missing another Mac.
            gap = repair.coverage_gap(slot)
            if gap and not reasons:
                reasons.append(f"omits {len(gap)} other registered Mac(s)")
                info(f"{slot.key}: widening to cover {', '.join(gap)}")
            if not reasons:
                continue
            repair.repair_slot(slot, res, devices, certs, all_udids)

        if not args.dry_run:
            changed = write_config({
                "TEAM_ID": cfg.get("TEAM_ID", ""),
                "DEV_IDENTITY": cfg.get("DEV_IDENTITY", ""),
                "DIST_IDENTITY": cfg.get("DIST_IDENTITY", ""),
                "BUNDLE_ID": cfg.get("BUNDLE_ID", ""),
                "EXT_BUNDLE_ID": cfg.get("EXT_BUNDLE_ID", ""),
                "DAEMON_BUNDLE_ID": cfg.get("DAEMON_BUNDLE_ID", ""),
                "APP_GROUP": cfg.get("APP_GROUP", ""),
            })
            if changed:
                ok(f"updated signing/local.config ({', '.join(changed)})")

        if repair.portal_steps and not args.dry_run:
            write_pending(repair.portal_steps)
            portal_instructions(cfg, repair.portal_steps)
    except AscError as exc:
        bad(f"App Store Connect: {exc}")
        return 0 if args.check else 1

    # --- re-check -------------------------------------------------------
    slots = slots_for(cfg)
    problems = {s.key: check_slot(s, cfg, udid, local_sha1s) for s in slots}
    remaining = [f"{k}: {'; '.join(v)}" for k, v in problems.items() if v]
    if remaining:
        for line in remaining:
            warn(line)
        warn("build continues; affected components sign without entitlements")
    else:
        PENDING_PATH.unlink(missing_ok=True)
        ok("signing is healthy on this Mac")
    return 0 if args.check else (1 if remaining else 0)


def report(slots: list[Slot], problems: dict[str, list[str]], cfg: dict[str, str],
           udid: str, identities: list[tuple[str, str]], verbose: bool) -> None:
    if not verbose:
        say("→ signing preflight: ok")
        return
    say("Signing status")
    say(f"  team       {cfg.get('TEAM_ID', '(unset)')}")
    say(f"  app group  {cfg.get('APP_GROUP', '(unset)')}")
    say(f"  keychain   {keychain_group(cfg) or '(unset)'}")
    say(f"  this Mac   {udid or '(unknown)'}  {computer_name()}")
    say("  identities:")
    for _, name in identities or []:
        say(f"    {name}")
    if not identities:
        say("    (none — builds will be ad-hoc signed)")
    say("  profiles:")
    for slot in slots:
        issues = problems[slot.key]
        profile = Profile.decode(slot.path) if slot.path.exists() else None
        detail = ""
        if profile:
            detail = (f"{len(profile.devices)} Mac(s), "
                      f"expires {profile.expires:%Y-%m-%d}" if profile.expires
                      else f"{len(profile.devices)} Mac(s)")
        if issues:
            bad(f"{slot.filename}: {'; '.join(issues)}")
        else:
            ok(f"{slot.filename}: {detail}")


def main() -> int:
    global _QUIET
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="verify and repair if needed; never fails the build (default)")
    mode.add_argument("--repair", action="store_true",
                      help="repair even if the local check passes")
    mode.add_argument("--status", action="store_true",
                      help="report only; exit 1 when unhealthy")
    parser.add_argument("--dry-run", action="store_true",
                        help="with --repair, print the Apple API calls without making them")
    parser.add_argument("--keep-old", action="store_true",
                        help="do not delete profiles that a new one supersedes")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if not (args.check or args.repair or args.status):
        args.check = True
    _QUIET = args.quiet

    if args.check and not args.repair:
        if os.environ.get("CI"):
            return 0
        if os.environ.get("WIKI_SIGNING_PREFLIGHT") == "0":
            return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
