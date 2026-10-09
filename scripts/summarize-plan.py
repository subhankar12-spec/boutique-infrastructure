#!/usr/bin/env python3
"""Read private Terraform plan JSON from stdin; emit resource actions only.

Never include variables, planned values, before/after attributes or outputs:
Terraform JSON contains sensitive values even when the terminal plan masks them.
"""
import json
import sys
from collections import Counter


def summarize(plan):
    counts = Counter()
    resources = []
    for resource in plan.get("resource_changes", []):
        actions = resource["change"]["actions"]
        if actions == ["no-op"]:
            continue
        action = "/".join(actions)
        counts[action] += 1
        resources.append({"address": resource["address"], "type": resource["type"], "actions": actions})
    return {"terraform_version": plan.get("terraform_version", "unknown"),
            "action_counts": dict(sorted(counts.items())),
            "resources": sorted(resources, key=lambda item: item["address"])}


if __name__ == "__main__":
    json.dump(summarize(json.load(sys.stdin)), sys.stdout, indent=2)
    sys.stdout.write("\n")
