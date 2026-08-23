#!/usr/bin/env python3
#
# One OCI instance's status, as a single JSON document on stdout.
#
# Every number here is Oracle's own: the metered quantities come from the Usage
# API rather than from multiplying the shape by elapsed time, because a resized
# instance makes that multiplication wrong (a box that ran at 4 OCPU for half a
# month and 2 for the rest has consumed far more than its current shape implies).
# Live utilisation comes from Monitoring, and the shape and boot volume from
# Compute.
#
# Authentication reuses the API key already in ~/.oci/config - the same
# credential the oci CLI reads - but the CLI itself is never invoked: requests
# are signed here, the way the instance-metadata dashboards do it.
#
# Usage: vps_status.py [--instance NAME] [--profile DEFAULT]

import argparse
import base64
import configparser
import datetime
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

# Always Free allowances for the Ampere A1 shape family, per tenancy per month.
OCPU_HOUR_LIMIT = 3000.0
RAM_GB_HOUR_LIMIT = 18000.0
EGRESS_GB_LIMIT = 10000.0

# SKU part numbers, so a display-name change upstream cannot silently zero a
# meter. The names are kept only for display.
SKU_OCPU = "B93297"
SKU_MEMORY = "B93298"
SKU_EGRESS = "B93455"

TIMEOUT = 25


class Signer:
    """Signs OCI REST requests with the key pair from ~/.oci/config."""

    def __init__(self, profile: str) -> None:
        path = os.path.expanduser("~/.oci/config")
        if not os.path.isfile(path):
            raise RuntimeError("no ~/.oci/config; run `oci setup config` once")
        parser = configparser.ConfigParser()
        parser.read(path)
        if profile not in parser:
            raise RuntimeError(f"profile [{profile}] not in ~/.oci/config")
        section = parser[profile]
        for key in ("user", "fingerprint", "key_file", "tenancy", "region"):
            if not section.get(key):
                raise RuntimeError(f"profile [{profile}] is missing {key}")
        key_path = os.path.expanduser(section["key_file"])
        with open(key_path, "rb") as handle:
            self._key = serialization.load_pem_private_key(handle.read(), password=None)
        self.tenancy = section["tenancy"]
        self.region = section["region"]
        self._key_id = f'{self.tenancy}/{section["user"]}/{section["fingerprint"]}'

    def _sign(self, message: str) -> str:
        signature = self._key.sign(message.encode(), padding.PKCS1v15(), hashes.SHA256())
        return base64.b64encode(signature).decode()

    def _authorization(self, headers: str, signature: str) -> str:
        return (
            f'Signature version="1",keyId="{self._key_id}",'
            f'algorithm="rsa-sha256",headers="{headers}",signature="{signature}"'
        )

    @staticmethod
    def _now() -> str:
        return datetime.datetime.now(datetime.timezone.utc).strftime(
            "%a, %d %b %Y %H:%M:%S GMT"
        )

    def get(self, host: str, path: str):
        date = self._now()
        signed = f"(request-target): get {path}\nhost: {host}\ndate: {date}"
        request = urllib.request.Request(
            f"https://{host}{path}",
            headers={
                "date": date,
                "host": host,
                "Accept": "application/json",
                "Authorization": self._authorization(
                    "(request-target) host date", self._sign(signed)
                ),
            },
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)

    def post(self, host: str, path: str, body: dict):
        raw = json.dumps(body).encode()
        date = self._now()
        digest = base64.b64encode(hashlib.sha256(raw).digest()).decode()
        signed = (
            f"(request-target): post {path}\nhost: {host}\ndate: {date}\n"
            f"content-type: application/json\nx-content-sha256: {digest}\n"
            f"content-length: {len(raw)}"
        )
        request = urllib.request.Request(
            f"https://{host}{path}",
            data=raw,
            method="POST",
            headers={
                "date": date,
                "host": host,
                "Accept": "application/json",
                "content-type": "application/json",
                "x-content-sha256": digest,
                "content-length": str(len(raw)),
                "Authorization": self._authorization(
                    "(request-target) host date content-type "
                    "x-content-sha256 content-length",
                    self._sign(signed),
                ),
            },
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)

    def post_action(self, host: str, path: str):
        """A POST whose whole meaning is in the path - an instance action.

        The body is empty, which still has to be signed: an unsigned length or
        digest is rejected, and a JSON "{}" is not the same thing as nothing.
        """
        raw = b""
        date = self._now()
        digest = base64.b64encode(hashlib.sha256(raw).digest()).decode()
        signed = (
            f"(request-target): post {path}\nhost: {host}\ndate: {date}\n"
            f"content-type: application/json\nx-content-sha256: {digest}\n"
            f"content-length: 0"
        )
        request = urllib.request.Request(
            f"https://{host}{path}",
            data=raw,
            method="POST",
            headers={
                "date": date,
                "host": host,
                "Accept": "application/json",
                "content-type": "application/json",
                "x-content-sha256": digest,
                "content-length": "0",
                "Authorization": self._authorization(
                    "(request-target) host date content-type "
                    "x-content-sha256 content-length",
                    self._sign(signed),
                ),
            },
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)


def month_window(now: datetime.datetime):
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if now.month == 12:
        end = start.replace(year=now.year + 1, month=1)
    else:
        end = start.replace(month=now.month + 1)
    return start, end


def iso(moment: datetime.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def find_instance(signer: Signer, name: str):
    """The named running instance, searched tenancy-wide then in subcompartments."""
    compartments = [signer.tenancy]
    try:
        listed = signer.get(
            f"identity.{signer.region}.oci.oraclecloud.com",
            f"/20160918/compartments?compartmentId={signer.tenancy}"
            "&compartmentIdInSubtree=true&accessLevel=ACCESSIBLE&limit=100",
        )
        compartments += [c["id"] for c in listed if c.get("lifecycleState") == "ACTIVE"]
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError):
        pass  # the root compartment alone is a normal single-instance tenancy

    wanted = (name or "").strip().casefold()
    fallback = None
    for compartment in compartments:
        try:
            instances = signer.get(
                f"iaas.{signer.region}.oraclecloud.com",
                f"/20160918/instances?compartmentId={compartment}&limit=100",
            )
        except (urllib.error.URLError, urllib.error.HTTPError):
            continue
        for instance in instances:
            if instance.get("lifecycleState") == "TERMINATED":
                continue
            instance["_compartmentId"] = compartment
            if not wanted:
                return instance
            if (instance.get("displayName") or "").strip().casefold() == wanted:
                return instance
            fallback = fallback or instance
    return fallback


def boot_volume(signer: Signer, instance: dict) -> dict:
    host = f"iaas.{signer.region}.oraclecloud.com"
    try:
        attachments = signer.get(
            host,
            "/20160918/bootVolumeAttachments"
            f"?availabilityDomain={instance['availabilityDomain']}"
            f"&compartmentId={instance['_compartmentId']}"
            f"&instanceId={instance['id']}",
        )
        for attachment in attachments:
            volume = signer.get(host, f"/20160918/bootVolumes/{attachment['bootVolumeId']}")
            return {
                "sizeGb": float(volume.get("sizeInGBs") or 0),
                "vpusPerGb": float(volume.get("vpusPerGB") or 0),
                "state": volume.get("lifecycleState", ""),
            }
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError):
        pass
    return {"sizeGb": 0.0, "vpusPerGb": 0.0, "state": ""}


def live_metrics(signer: Signer, instance: dict) -> dict:
    """Latest utilisation and throughput, per Monitoring.

    The byte counters are cumulative and reset whenever the agent restarts, so
    they are asked for as `.rate()` - a difference per second, which a reset
    turns negative and which is therefore discarded rather than believed.
    """
    host = f"telemetry.{signer.region}.oraclecloud.com"
    now = datetime.datetime.now(datetime.timezone.utc)
    start = now - datetime.timedelta(hours=1)
    dimension = f'{{resourceId = "{instance["id"]}"}}'
    out = {
        "cpuPercent": None, "memoryPercent": None, "loadAverage": None,
        "netInRate": None, "netOutRate": None,
        "diskReadRate": None, "diskWriteRate": None,
    }
    queries = {
        "cpuPercent": f"CpuUtilization[5m]{dimension}.mean()",
        "memoryPercent": f"MemoryUtilization[5m]{dimension}.mean()",
        "loadAverage": f"LoadAverage[5m]{dimension}.mean()",
        "netInRate": f"NetworksBytesIn[5m]{dimension}.rate()",
        "netOutRate": f"NetworksBytesOut[5m]{dimension}.rate()",
        "diskReadRate": f"DiskBytesRead[5m]{dimension}.rate()",
        "diskWriteRate": f"DiskBytesWritten[5m]{dimension}.rate()",
    }
    for field, query in queries.items():
        try:
            result = signer.post(
                host,
                f"/20180401/metrics/actions/summarizeMetricsData"
                f"?compartmentId={instance['_compartmentId']}",
                {
                    "namespace": "oci_computeagent",
                    "query": query,
                    "startTime": iso(start),
                    "endTime": iso(now),
                },
            )
            points = [
                point["value"]
                for series in result
                for point in series.get("aggregatedDatapoints", [])
            ]
            if field.endswith("Rate"):
                # A negative rate is the counter having restarted, not traffic
                # flowing backwards.
                points = [value for value in points if value >= 0]
            if points:
                out[field] = round(points[-1], 2)
        except (urllib.error.URLError, urllib.error.HTTPError, KeyError, IndexError):
            continue
    return out


def metered_usage(signer: Signer, now: datetime.datetime) -> dict:
    """Month-to-date metered quantities, keyed by SKU part number.

    This is the figure Oracle bills against the Always Free allowance, so it
    already accounts for any resize during the month.
    """
    start, _ = month_window(now)
    result = signer.post(
        f"usageapi.{signer.region}.oci.oraclecloud.com",
        "/20200107/usage",
        {
            "tenantId": signer.tenancy,
            "timeUsageStarted": start.strftime("%Y-%m-%dT00:00:00Z"),
            "timeUsageEnded": now.strftime("%Y-%m-%dT00:00:00Z"),
            "granularity": "DAILY",
            "queryType": "USAGE",
            "groupBy": ["skuPartNumber", "skuName"],
        },
    )
    totals: dict[str, dict] = {}
    daily: dict[str, dict[str, float]] = {}
    for item in result.get("items", []):
        part = item.get("skuPartNumber") or ""
        quantity = float(item.get("computedQuantity") or 0)
        entry = totals.setdefault(
            part, {"name": item.get("skuName") or "", "quantity": 0.0, "unit": item.get("unit") or ""}
        )
        entry["quantity"] += quantity
        day = (item.get("timeUsageStarted") or "")[:10]
        if day:
            daily.setdefault(part, {})
            daily[part][day] = daily[part].get(day, 0.0) + quantity
    return {"totals": totals, "daily": daily}


def guard_status(percent: float) -> str:
    if percent > 100:
        return "over"
    if percent >= 90:
        return "critical"
    if percent >= 75:
        return "watch"
    return "safe"


def egress_status(gb: float) -> str:
    """The shared script's own bands, in GB."""
    if gb >= 8000:
        return "over"
    if gb >= 7000:
        return "critical"
    if gb >= 5000:
        return "watch"
    return "safe"


def meter(used: float, limit: float, projected: float) -> dict:
    percent = (used / limit * 100) if limit else 0.0
    projected_percent = (projected / limit * 100) if limit else 0.0
    return {
        "used": round(used, 2),
        "limit": limit,
        "percent": round(percent, 2),
        "projected": round(projected, 2),
        "projectedPercent": round(projected_percent, 2),
        "status": guard_status(percent),
        "projectedStatus": guard_status(projected_percent),
    }


# Always Free gives 200 GB of block storage in total, boot volumes included, at
# up to 10 VPU/GB. Both halves of that sentence can be breached separately.
STORAGE_GB_LIMIT = 200.0
FREE_VPUS_PER_GB = 10.0


def attached_block_gb(signer: Signer, compartment: str) -> float:
    """Every non-boot block volume's size, which shares the 200 GB allowance."""
    try:
        volumes = signer.get(
            f"iaas.{signer.region}.oraclecloud.com",
            f"/20160918/volumes?compartmentId={compartment}&limit=100",
        )
        return sum(
            float(volume.get("sizeInGBs") or 0)
            for volume in volumes
            if volume.get("lifecycleState") == "AVAILABLE"
        )
    except (urllib.error.URLError, urllib.error.HTTPError):
        return 0.0

def build(instance_name: str, profile: str) -> dict:
    signer = Signer(profile)
    now = datetime.datetime.now(datetime.timezone.utc)
    month_start, month_end = month_window(now)

    instance = find_instance(signer, instance_name)
    if instance is None:
        raise RuntimeError(
            f"no instance named {instance_name!r} in tenancy" if instance_name
            else "tenancy has no non-terminated instances"
        )

    shape = instance.get("shapeConfig") or {}
    ocpus = float(shape.get("ocpus") or 0)
    memory_gb = float(shape.get("memoryInGBs") or 0)

    usage = metered_usage(signer, now)
    totals = usage["totals"]
    ocpu_hours = totals.get(SKU_OCPU, {}).get("quantity", 0.0)
    ram_hours = totals.get(SKU_MEMORY, {}).get("quantity", 0.0)
    egress_gb = totals.get(SKU_EGRESS, {}).get("quantity", 0.0)

    # Usage is metered to midnight, so project the rest of today at the shape
    # running now, then the remaining whole days at the same rate.
    remaining_hours = max(0.0, (month_end - now).total_seconds() / 3600)
    hours_today = (now - now.replace(hour=0, minute=0, second=0, microsecond=0)).total_seconds() / 3600
    ocpu_projected = ocpu_hours + ocpus * (remaining_hours + hours_today)
    ram_projected = ram_hours + memory_gb * (remaining_hours + hours_today)
    days_elapsed = max(1e-9, (now - month_start).total_seconds() / 86400)
    egress_projected = egress_gb / days_elapsed * ((month_end - month_start).total_seconds() / 86400)

    boot = boot_volume(signer, instance)
    block_gb = attached_block_gb(signer, instance["_compartmentId"])
    allocated_gb = boot["sizeGb"] + block_gb

    return {
        "ok": True,
        "generatedAt": now.isoformat(timespec="seconds"),
        "instance": {
            "name": instance.get("displayName", ""),
            "state": instance.get("lifecycleState", ""),
            "shape": instance.get("shape", ""),
            "ocpus": ocpus,
            "memoryGb": memory_gb,
            "region": signer.region,
            "availabilityDomain": instance.get("availabilityDomain", ""),
            "faultDomain": instance.get("faultDomain", ""),
            "created": instance.get("timeCreated", ""),
            "processor": shape.get("processorDescription", ""),
            "bandwidthGbps": float(shape.get("networkingBandwidthInGbps") or 0),
            "maxVnics": int(shape.get("maxVnicAttachments") or 0),
        },
        "live": live_metrics(signer, instance),
        # One point per metered day, oldest first. A resize shows up here as a
        # step rather than as a slope, which is the whole reason the panel plots
        # it: the shape running now says nothing about what the month has cost.
        "dailyOcpuHours": [
            {"day": day, "hours": round(hours, 2)}
            for day, hours in sorted(usage["daily"].get(SKU_OCPU, {}).items())
        ],
        "dailyEgressGb": [
            {"day": day, "gb": round(gb, 3)}
            for day, gb in sorted(usage["daily"].get(SKU_EGRESS, {}).items())
        ],
        "freeTier": {
            "ocpu": meter(ocpu_hours, OCPU_HOUR_LIMIT, ocpu_projected),
            "memory": meter(ram_hours, RAM_GB_HOUR_LIMIT, ram_projected),
        },
        "egress": {
            **meter(egress_gb, EGRESS_GB_LIMIT, egress_projected),
            "status": egress_status(egress_gb),
            "projectedStatus": egress_status(egress_projected),
        },
        "storage": {
            "bootSizeGb": boot["sizeGb"],
            "bootVpusPerGb": boot["vpusPerGb"],
            "bootState": boot["state"],
            # Above the free 10 VPU/GB performance tier the volume is billable.
            "bootVpuBillable": boot["vpusPerGb"] > FREE_VPUS_PER_GB,
            "blockGb": block_gb,
            "allocatedGb": allocated_gb,
            "allocationLimitGb": STORAGE_GB_LIMIT,
            "allocationPercent": round(allocated_gb / STORAGE_GB_LIMIT * 100, 1) if STORAGE_GB_LIMIT else 0.0,
            "allocationFull": allocated_gb >= STORAGE_GB_LIMIT,
        },
        "skus": [
            {"part": part, "name": entry["name"], "quantity": round(entry["quantity"], 2)}
            for part, entry in sorted(
                totals.items(), key=lambda kv: -kv[1]["quantity"]
            )
        ],
    }


# What the panel's three buttons mean, spelled out so a graceful shutdown is
# never silently turned into a power cut. STOP/RESET (the hard pair) are
# accepted but not offered by the UI.
ACTIONS = {
    "start": "START",
    "stop": "SOFTSTOP",
    "reboot": "SOFTRESET",
    "forcestop": "STOP",
    "forcereboot": "RESET",
}

# An action only makes sense from certain states, and the API's error for a
# wrong one is opaque, so the refusal happens here where it can be explained.
VALID_FROM = {
    "START": {"STOPPED"},
    "SOFTSTOP": {"RUNNING"},
    "STOP": {"RUNNING"},
    "SOFTRESET": {"RUNNING"},
    "RESET": {"RUNNING"},
}


def act(instance_name: str, profile: str, action: str, dry_run: bool) -> dict:
    """Run one lifecycle action against the instance."""
    resolved = ACTIONS.get(action.strip().casefold())
    if resolved is None:
        raise RuntimeError(f"unknown action {action!r}; expected one of {', '.join(sorted(ACTIONS))}")

    signer = Signer(profile)
    instance = find_instance(signer, instance_name)
    if instance is None:
        raise RuntimeError("no instance to act on")

    state = instance.get("lifecycleState", "")
    allowed = VALID_FROM.get(resolved, set())
    if state not in allowed:
        raise RuntimeError(
            f"{resolved} needs the instance to be {' or '.join(sorted(allowed))}, not {state}"
        )

    path = f"/20160918/instances/{instance['id']}?action={resolved}"
    host = f"iaas.{signer.region}.oraclecloud.com"
    if dry_run:
        return {"ok": True, "dryRun": True, "action": resolved, "from": state,
                "request": f"POST https://{host}{path}"}

    result = signer.post_action(host, path)
    return {
        "ok": True,
        "action": resolved,
        "from": state,
        "state": result.get("lifecycleState", ""),
        "name": result.get("displayName", ""),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instance", default="", help="instance display name")
    parser.add_argument("--profile", default="DEFAULT", help="~/.oci/config profile")
    parser.add_argument("--action", default="", help=f"one of: {', '.join(sorted(ACTIONS))}")
    parser.add_argument("--dry-run", action="store_true",
                        help="with --action, report the request instead of sending it")
    args = parser.parse_args()
    try:
        if args.action:
            print(json.dumps(act(args.instance, args.profile, args.action, args.dry_run)))
        else:
            print(json.dumps(build(args.instance, args.profile)))
        return 0
    except urllib.error.HTTPError as error:
        detail = ""
        try:
            detail = json.loads(error.read().decode()).get("message", "")
        except Exception:
            pass
        print(json.dumps({"ok": False, "error": f"HTTP {error.code}: {detail or error.reason}"}))
        return 0
    except Exception as error:  # a dashboard reports its own failure, never crashes
        print(json.dumps({"ok": False, "error": str(error)}))
        return 0


if __name__ == "__main__":
    sys.exit(main())
