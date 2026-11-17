#!/usr/bin/env bash
# Merge LoopForge default Docker Hub registry-mirrors into the Docker Engine config.
#
# Usage:
#   bash scripts/configure-docker-registry-mirrors.sh
#   LOOPFORGE_DOCKER_MIRROR_ALIYUN=https://xxxx.mirror.aliyuncs.com bash scripts/configure-docker-registry-mirrors.sh
#
# Linux: writes /etc/docker/daemon.json (needs sudo). macOS Docker Desktop: ~/.docker/daemon.json.
# Aliyun URL: https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
#
# registry-mirrors only accelerates Docker Hub. For ghcr.io use MIRROR=ghcr.nju.edu.cn — README.zh-CN.md.
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
DEFAULTS="$ROOT/scripts/docker-registry-mirrors.defaults.json"
[[ -f "$DEFAULTS" ]] || { echo "missing $DEFAULTS" >&2; exit 1; }

pick_config() {
  if [[ $(uname -s) == Linux ]] && [[ -w /etc/docker/daemon.json || -w /etc/docker ]]; then
    printf '%s\n' /etc/docker/daemon.json
  elif [[ $(uname -s) == Linux ]]; then
    printf '%s\n' /etc/docker/daemon.json
  else
    printf '%s\n' "${HOME}/.docker/daemon.json"
  fi
}

CONFIG="$(pick_config)"
USE_SUDO=0
if [[ "$CONFIG" == /etc/docker/* ]] && [[ ! -w "$CONFIG" ]] && [[ ! -w "$(dirname "$CONFIG")" ]]; then
  USE_SUDO=1
fi

python3 - "$CONFIG" "$DEFAULTS" "$USE_SUDO" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, time

config_path = pathlib.Path(sys.argv[1])
defaults_path = pathlib.Path(sys.argv[2])
use_sudo = sys.argv[3] == "1"
aliyun = (os.environ.get("LOOPFORGE_DOCKER_MIRROR_ALIYUN") or "").strip().rstrip("/")

def load_list():
    mirrors = [str(x).strip().rstrip("/") for x in json.loads(defaults_path.read_text()) if str(x).strip()]
    if aliyun:
        if not aliyun.startswith(("http://", "https://")):
            aliyun_url = "https://" + aliyun
        else:
            aliyun_url = aliyun
        if aliyun_url not in mirrors:
            mirrors.insert(0, aliyun_url)
    return mirrors

def read_cfg(path: pathlib.Path) -> dict:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return {}
    return json.loads(text)

def write_cfg(path: pathlib.Path, cfg: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(cfg, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    if use_sudo:
        tmp = pathlib.Path("/tmp") / f"loopforge-daemon-{int(time.time())}.json"
        tmp.write_bytes(data)
        subprocess.run(["sudo", "cp", str(tmp), str(path)], check=True)
        tmp.unlink(missing_ok=True)
    else:
        if path.is_file():
            backup = path.with_suffix(path.suffix + f".bak-{time.strftime('%Y%m%d-%H%M%S')}")
            shutil.copy2(path, backup)
            print(f"Backed up to {backup}")
        path.write_bytes(data)

cfg = read_cfg(config_path)
cfg["registry-mirrors"] = load_list()
write_cfg(config_path, cfg)
print(f"Updated {config_path}")
for m in cfg["registry-mirrors"]:
    print(f"  {m}")
print()
if use_sudo:
    print("Restart Docker: sudo systemctl restart docker")
else:
    print("Restart Docker Desktop or the Docker daemon, then: docker info | grep -A5 'Registry Mirrors'")
PY