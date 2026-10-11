#!/usr/bin/env python3
"""Valida los scripts embebidos en los ConfigMaps.

Para cada ConfigMap de los manifiestos renderizados, extrae las claves *.sh y
les corre `bash -n` (y `shellcheck -S warning` si esta instalado).

Uso:
    oc kustomize manifests/overlays/lab > /tmp/lab.yaml
    tools/check-scripts.py /tmp/lab.yaml
"""
import os
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    print("ERROR: falta pyyaml (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def check(paths):
    failures = 0
    for path in paths:
        with open(path) as fh:
            for doc in yaml.safe_load_all(fh):
                if not doc or doc.get("kind") != "ConfigMap":
                    continue
                name = doc["metadata"]["name"]
                for key, value in (doc.get("data") or {}).items():
                    if not key.endswith(".sh"):
                        continue
                    with tempfile.NamedTemporaryFile(
                        "w", suffix=".sh", delete=False
                    ) as tmp:
                        tmp.write(value)
                        tmp_path = tmp.name
                    try:
                        cmds = [["bash", "-n", tmp_path]]
                        if shutil.which("shellcheck"):
                            cmds.append(["shellcheck", "-S", "warning", tmp_path])
                        for cmd in cmds:
                            result = subprocess.run(
                                cmd, capture_output=True, text=True
                            )
                            label = f"{name}/{key} [{cmd[0]}]"
                            if result.returncode:
                                failures += 1
                                print(f"FAIL {label}")
                                print((result.stdout + result.stderr).strip())
                            else:
                                print(f"ok   {label}")
                    finally:
                        os.unlink(tmp_path)
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(check(sys.argv[1:]))
