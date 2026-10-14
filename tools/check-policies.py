#!/usr/bin/env python3
"""check-policies.py -- enforce the AGENTS.md hard rules on rendered manifests.

Usage: check-policies.py <rendered.yaml> [more.yaml ...]

Checks (see AGENTS.md):
  1. every container image is a UBI image pinned by digest, and nothing uses
     docker.io/library/postgres (a documented allowlist covers components that
     have no UBI image, e.g. the metrics exporter);
  2. no operators: no CRDs and no OLM objects;
  3. the namespace is `plain-pg` (rule 4);
  4. auxiliary pod templates do not carry name/instance=postgresql, so they can
     never become endpoints of the database Services (rule 8);
  5. pods stay inside PodSecurity "restricted" (no privileged/host namespaces).
"""
import sys

import yaml

NAMESPACE = "plain-pg"
IMAGE_RE = "registry.redhat.io/"
FORBIDDEN_KINDS = {
    "CustomResourceDefinition",
    "Subscription",
    "ClusterServiceVersion",
    "OperatorGroup",
    "InstallPlan",
}
# Path to the PodTemplateSpec (metadata + spec) inside each workload kind.
POD_TEMPLATE_PATHS = {
    "StatefulSet": ["spec", "template"],
    "Deployment": ["spec", "template"],
    "DaemonSet": ["spec", "template"],
    "ReplicaSet": ["spec", "template"],
    "Job": ["spec", "template"],
    "CronJob": ["spec", "jobTemplate", "spec", "template"],
}
# Non-UBI images that are allowed because Red Hat does not publish one. They must
# still be pinned by digest. Keep this list short and documented.
NON_UBI_ALLOWED = {
    "quay.io/prometheuscommunity/postgres-exporter":
        "metrics exporter (components/metrics)",
}

problems = []


def fail(msg):
    problems.append(msg)


def pod_templates(doc):
    """Yield (labels, pod_spec) for every pod template in the object."""
    if doc.get("kind") == "Pod":
        yield doc.get("metadata", {}).get("labels", {}), doc.get("spec", {})
        return
    path = POD_TEMPLATE_PATHS.get(doc.get("kind"))
    if not path:
        return
    node = doc
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return
        node = node[key]
    if isinstance(node, dict):
        yield (node.get("metadata") or {}).get("labels", {}), node.get("spec") or {}


def check_doc(doc):
    kind = doc.get("kind", "?")
    name = doc.get("metadata", {}).get("name", "?")
    where = f"{kind}/{name}"

    if kind in FORBIDDEN_KINDS:
        fail(f"{where}: operators/CRDs are forbidden (rule 1)")

    meta = doc.get("metadata", {})
    if kind == "Namespace":
        if meta.get("name") != NAMESPACE:
            fail(f"{where}: namespace must be {NAMESPACE} (rule 4)")
    elif meta.get("namespace") != NAMESPACE:
        fail(f"{where}: namespace must be {NAMESPACE} (rule 4)")

    for labels, spec in pod_templates(doc):
        if kind != "StatefulSet" or name != "postgresql":
            if labels.get("app.kubernetes.io/name") == "postgresql":
                fail(f"{where}: auxiliary pod template has name=postgresql (rule 8)")
            if labels.get("app.kubernetes.io/instance") == "postgresql":
                fail(f"{where}: auxiliary pod template has instance=postgresql (rule 8)")

        if spec.get("hostNetwork") or spec.get("hostPID") or spec.get("hostIPC"):
            fail(f"{where}: host namespaces are not allowed under PodSecurity restricted")

        containers = list(spec.get("initContainers") or []) + list(spec.get("containers") or [])
        for c in containers:
            image = c.get("image", "")
            if "docker.io/library/postgres" in image:
                fail(f"{where}: docker.io/library/postgres is forbidden (rule 3)")
            allowed = any(image.startswith(p) for p in NON_UBI_ALLOWED)
            if not allowed and IMAGE_RE not in image:
                fail(f"{where}: image {image!r} is not a UBI image (rule 3)")
            if "@sha256:" not in image:
                fail(f"{where}: image {image!r} is not pinned by digest (rule 3)")
            sc = c.get("securityContext", {}) or {}
            if sc.get("privileged"):
                fail(f"{where}: privileged container {c.get('name')!r}")


def main(paths):
    docs = []
    for path in paths:
        with open(path) as fh:
            docs += [d for d in yaml.safe_load_all(fh) if d]
    for doc in docs:
        check_doc(doc)

    for p in problems:
        print(f"FAIL {p}")
    print(f"checked {len(docs)} objects in {len(paths)} file(s): "
          f"{len(problems)} violation(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
