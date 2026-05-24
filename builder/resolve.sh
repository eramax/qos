#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

usage() {
  cat <<'EOF'
Usage: builder/resolve.sh <command> [options]

Commands:
  stage --profile <name> --out-dir <dir>
  packages --profile <name>
  qemu --profile <name>
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 1
  }
}

require_cmd python3

python3 - "$repo_root" "$@" <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

import yaml

repo_root = Path(sys.argv[1])
argv = sys.argv[2:]


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


if not argv:
    die("missing command")

command = argv[0]
args = argv[1:]


def parse_flag(args, flag):
    if flag not in args:
        return None
    idx = args.index(flag)
    if idx + 1 >= len(args):
        die(f"missing value for {flag}")
    return args[idx + 1]


profiles_dir = repo_root / "profiles"
components_dir = repo_root / "components"
repos_file = repo_root / "components" / "apk" / "repositories"
base_kernel_config = repo_root / "components" / "kernel" / "kernel" / "x86_64.config"
base_kernel_version_file = repo_root / "components" / "kernel" / "kernel" / "version"


def load_yaml(path: Path):
    if not path.is_file():
        die(f"missing YAML file: {path}")
    with path.open() as fh:
        return yaml.safe_load(fh) or {}


def load_profile(name: str):
    path = profiles_dir / f"{name}.yaml"
    data = load_yaml(path)
    if data.get("name") != name:
        die(f"profile name mismatch in {path}")
    return data


def load_component(name: str):
    path = components_dir / name / "component.yaml"
    data = load_yaml(path)
    if data.get("name") != name:
        die(f"component name mismatch in {path}")
    return data


def _inside_repo(path: Path) -> bool:
    try:
        path.resolve().relative_to(repo_root.resolve())
        return True
    except ValueError:
        return False


def resolve_profile(name: str):
    ordered = []
    seen_components = set()
    resolving_profiles = set()
    kernel_base = None
    kernel_fragments = []
    kernel_version = None
    qemu_command = None

    def add_component(component_name: str):
        if component_name in seen_components:
            return
        component = load_component(component_name)
        for dep in component.get("depends_on", []) or []:
            add_component(dep)
        seen_components.add(component_name)
        ordered.append(component_name)

    def walk_profile(profile_name: str):
        nonlocal kernel_base, kernel_version, qemu_command
        if profile_name in resolving_profiles:
            die(f"profile cycle detected at {profile_name}")
        resolving_profiles.add(profile_name)
        profile = load_profile(profile_name)
        parent = profile.get("extends")
        if parent:
            walk_profile(parent)
        kernel_cfg = profile.get("kernel", {}) or {}
        base_cfg = kernel_cfg.get("base_config")
        if base_cfg:
            kernel_base = base_cfg
        ver = kernel_cfg.get("version")
        if ver:
            kernel_version = str(ver)
        for frag in kernel_cfg.get("fragments", []) or []:
            if frag not in kernel_fragments:
                kernel_fragments.append(frag)
        qemu_cfg = profile.get("qemu", {}) or {}
        cmd = qemu_cfg.get("command")
        if cmd:
            qemu_command = str(cmd)
        for component_name in profile.get("components", []) or []:
            add_component(component_name)
        resolving_profiles.remove(profile_name)

    walk_profile(name)
    if not kernel_base:
        kernel_base = str(base_kernel_config.relative_to(repo_root))
    if not kernel_version:
        kernel_version = base_kernel_version_file.read_text().strip()
    return ordered, kernel_base, kernel_fragments, kernel_version, qemu_command


def resolved_packages(component_names):
    packages = []
    seen = set()
    for component_name in component_names:
        component = load_component(component_name)
        for package in component.get("packages", []) or []:
            if package not in seen:
                seen.add(package)
                packages.append(package)
    return packages


def ensure_mode(path: Path, mode: int) -> None:
    current = stat.S_IMODE(path.stat().st_mode)
    path.chmod(current | mode)


def copy_tree_contents(src: Path, dest: Path) -> None:
    if not src.is_dir():
        return
    for item in sorted(src.iterdir(), key=lambda p: p.name):
        target = dest / item.name
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            copy_tree_contents(item, target)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)


def stage_profile(profile_name: str, out_dir: Path):
    component_names, kernel_base_rel, kernel_fragment_rels, kernel_version, qemu_command = resolve_profile(profile_name)
    out_dir.mkdir(parents=True, exist_ok=True)
    rootfs_dir = out_dir / "rootfs"
    apk_dir = out_dir / "apk"
    kernel_dir = out_dir / "kernel"
    metadata_dir = out_dir / "metadata"
    for directory in (rootfs_dir, apk_dir, kernel_dir, metadata_dir):
        directory.mkdir(parents=True, exist_ok=True)

    packages = resolved_packages(component_names)
    (apk_dir / "packages.txt").write_text("".join(f"{pkg}\n" for pkg in packages))
    shutil.copy2(repos_file, apk_dir / "repositories")

    kernel_base_path = (repo_root / kernel_base_rel).resolve()
    if not kernel_base_path.is_file() or not _inside_repo(kernel_base_path):
        die(f"invalid kernel base config: {kernel_base_rel}")
    kernel_parts = [kernel_base_path.read_text()]
    for frag_rel in kernel_fragment_rels:
        frag_path = (repo_root / frag_rel).resolve()
        if not frag_path.is_file() or not _inside_repo(frag_path):
            die(f"invalid kernel fragment: {frag_rel}")
        kernel_parts.append(f"\n# profile fragment: {frag_rel}\n")
        kernel_parts.append(frag_path.read_text())
        if not kernel_parts[-1].endswith("\n"):
            kernel_parts.append("\n")
    (kernel_dir / "x86_64.config").write_text("".join(kernel_parts))
    (kernel_dir / "version").write_text(f"{kernel_version}\n")

    for component_name in component_names:
        component_dir = components_dir / component_name
        copy_tree_contents(component_dir / "rootfs", rootfs_dir)
        copy_tree_contents(component_dir / "s6" / "service-tree", rootfs_dir / "etc" / "s6" / "service-tree")
        copy_tree_contents(component_dir / "s6" / "s6-rc.d", rootfs_dir / "etc" / "s6" / "s6-rc.d")

    for run_file in rootfs_dir.glob("etc/s6/service-tree/*/run"):
        ensure_mode(run_file, 0o755)
    for run_file in rootfs_dir.glob("etc/s6/s6-rc.d/*/run"):
        ensure_mode(run_file, 0o755)
    for script_file in rootfs_dir.glob("etc/profile.d/*.sh"):
        ensure_mode(script_file, 0o755)

    (metadata_dir / "components.txt").write_text("".join(f"{name}\n" for name in component_names))
    if qemu_command:
        (metadata_dir / "qemu-command.sh").write_text(f"{qemu_command}\n")


if command == "packages":
    profile = parse_flag(args, "--profile")
    if not profile:
        die("usage: packages --profile <name>")
    component_names, _, _, _, _ = resolve_profile(profile)
    for package in resolved_packages(component_names):
        print(package)
elif command == "qemu":
    profile = parse_flag(args, "--profile")
    if not profile:
        die("usage: qemu --profile <name>")
    _, _, _, _, qemu_command = resolve_profile(profile)
    if not qemu_command:
        die(f"profile '{profile}' does not define qemu.command")
    print(qemu_command)
elif command == "stage":
    profile = parse_flag(args, "--profile")
    out_dir = parse_flag(args, "--out-dir")
    if not profile or not out_dir:
        die("usage: stage --profile <name> --out-dir <dir>")
    stage_profile(profile, Path(out_dir))
else:
    die(f"unknown command: {command}")
PY
