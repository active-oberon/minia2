#!/usr/bin/env python3
"""Create a minimal hosted A2 image and manage installable application ZIPs."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FORMAT = "minia2-app-v1"
CORE = {"WindowManager", "PET", "PETTrees", "PETModuleTree",
        "PETXMLTree", "PETReleaseTree", "FileHandlers", "Localization", "FSTools", "GDI32"}
EXT = {"Win64": ("GofWw", "SymWw"), "Linux64": ("GofUu", "SymUu"),
       "Linux32": ("GofU", "SymU"), "LinuxARM": ("GofA", "SymA")}
NAME = re.compile(r"[a-z][a-z0-9-]{0,63}$")
MAX_PACKAGE_BYTES = 100_000_000


def stop(message):
    raise ValueError(message)


def sha(body):
    return hashlib.sha256(body).hexdigest()


def app_sources():
    groups = {}
    for manifest in (ROOT / "packages/apps").glob("*/a2pkg.json"):
        data = json.loads(manifest.read_text(encoding="utf-8"))
        groups[data["name"].split("/")[-1]] = set(data["provides"])
    return groups


def sources_by_module():
    files = {}
    for path in (ROOT / "source").glob("*.Mod"):
        match = re.search(rb"\bMODULE\s+([A-Za-z][A-Za-z0-9_]*)", path.read_bytes()[:4096])
        if match:
            files[match.group(1).decode("ascii")] = path
    for path in (ROOT / "applications").glob("*/source/*.Mod"):
        match = re.search(rb"\bMODULE\s+([A-Za-z][A-Za-z0-9_]*)", path.read_bytes()[:4096])
        if match:
            files[match.group(1).decode("ascii")] = path
    return files


def keep_data():
    spec = ROOT / "configs/minimal-data.txt"
    patterns = [line.strip() for line in spec.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")]
    data = ROOT / "data"
    import fnmatch
    files = {path.name for path in data.iterdir() if path.is_file()}
    for pattern in patterns:
        if not any(fnmatch.fnmatchcase(name, pattern) for name in files):
            stop("unmatched core data pattern: " + pattern)
    return {name for name in files if any(fnmatch.fnmatchcase(name, p) for p in patterns)}


def reorganize(args):
    groups = app_sources()
    names = sources_by_module()
    moved = []
    for group, modules in groups.items():
        for module in sorted(modules):
            path = names.get(module)
            if path is None or path.parent != ROOT / "source":
                continue
            folder = "core" if module in CORE else group
            destination = ROOT / "applications" / folder / "source" / path.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                stop("destination already exists: " + str(destination))
            path.rename(destination)
            moved.append(str(destination.relative_to(ROOT)))
    core_data = keep_data()
    assets = ROOT / "applications/assets/data"
    assets.mkdir(parents=True, exist_ok=True)
    data_moved = 0
    for path in (ROOT / "data").iterdir():
        if path.is_file() and path.name not in core_data:
            destination = assets / path.name
            if destination.exists():
                stop("destination already exists: " + str(destination))
            path.rename(destination)
            data_moved += 1
    print(f"moved {len(moved)} application modules and {data_moved} optional data files")
    print(f"core data: {len(core_data)} files")


def manifest_ok(manifest, platform=None):
    if manifest.get("format") != FORMAT:
        stop("unsupported package format")
    name = manifest.get("name")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        stop("invalid package name")
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        stop("invalid package version")
    if manifest.get("platform") not in EXT or (platform and manifest["platform"] != platform):
        stop("wrong package platform")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        stop("package has no files")
    for path, checksum in files.items():
        parts = path.split("/")
        if (len(parts) != 2 or parts[0] not in ("bin", "data", "source")
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", parts[1])
                or "\\" in path or
                not re.fullmatch(r"[0-9a-f]{64}", str(checksum))):
            stop("invalid package entry: " + path)
        if parts[0] == "bin" and not path.endswith(tuple("." + x for x in EXT[manifest["platform"]])):
            stop("wrong object format: " + path)
    requires = manifest.get("requires", [])
    if not isinstance(requires, list) or any(not isinstance(x, str) or not NAME.fullmatch(x) for x in requires):
        stop("invalid requirements")
    return manifest


def zip_package(destination, manifest, files):
    manifest = dict(manifest, format=FORMAT, files={name: sha(body) for name, body in sorted(files.items())})
    manifest_ok(manifest)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("a2app.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        for name, body in sorted(files.items()):
            archive.writestr(name, body)


def read_package(path, platform):
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        if len(infos) > 10000 or sum(info.file_size for info in infos) > MAX_PACKAGE_BYTES:
            stop("package exceeds size or entry limit")
        entries = [info.filename for info in infos]
        if entries.count("a2app.json") != 1 or len(entries) != len(set(entries)):
            stop("missing or duplicate entries")
        if any(info.is_dir() or ((info.external_attr >> 16) & 0o170000) == 0o120000 for info in infos):
            stop("directories and symlinks are not allowed")
        manifest = manifest_ok(json.loads(archive.read("a2app.json")), platform)
        if set(entries) != {"a2app.json", *manifest["files"]}:
            stop("archive differs from its manifest")
        files = {name: archive.read(name) for name in manifest["files"]}
        for name, body in files.items():
            if sha(body) != manifest["files"][name]:
                stop("checksum mismatch: " + name)
    return manifest, files


def image_platform(image):
    path = image / "minia2-image.json"
    if not path.is_file():
        stop("not a minimal minia2 image: " + str(image))
    platform = json.loads(path.read_text(encoding="utf-8")).get("platform")
    if platform not in EXT:
        stop("unknown image platform")
    return platform


def installed(image):
    platform = image_platform(image)
    result = {}
    for path in sorted((image / "apps").glob("*/a2app.json")):
        manifest = manifest_ok(json.loads(path.read_text(encoding="utf-8")), platform)
        if path.parent.name != manifest["name"]:
            stop("package name and directory disagree: " + str(path))
        result[manifest["name"]] = manifest
    return result


def refresh_paths(image):
    lines = []
    for name, manifest in installed(image).items():
        for directory in ("bin", "data", "source"):
            if any(key.startswith(directory + "/") for key in manifest["files"]):
                lines.append(f"Files.AddSearchPath apps/{name}/{directory}~")
    (image / "apps.cfg").write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    config = image / "oberon.cfg"
    body = config.read_text(encoding="utf-8")
    command = "System.DoFile apps.cfg~"
    anchor = "Files.SetWorkPath work~"
    if anchor not in body:
        stop("oberon.cfg lacks Files.SetWorkPath")
    body = body.replace(command + "\n", "")
    config.write_text(body.replace(anchor, command + "\n" + anchor, 1), encoding="utf-8")


def build(args):
    platform = args.platform
    built = args.build.resolve()
    output = args.output.resolve()
    if output.exists() or not (built / "bin").is_dir() or not (built / "data").is_dir():
        stop("output exists or build has no bin/data")
    groups = app_sources()
    optional = set().union(*groups.values()) - CORE
    modules = sources_by_module()
    object_ext, symbol_ext = EXT[platform]
    archives = args.packages.resolve() / platform
    singles = {
        "clock": ({"WMClock"}, {"WMClock.rep"}, ["WMClock.Open"]),
        "calendar": ({"WMCalendar"}, set(), ["WMCalendar.Open"]),
        "diff": ({"DiffLib", "WMDiff"}, set(), ["WMDiff.Open"]),
    }
    single_modules = set().union(*(item[0] for item in singles.values()))
    single_data = set().union(*(item[1] for item in singles.values()))

    def files_for(members):
        files = {}
        for module in sorted(members):
            for ext in (object_ext, symbol_ext):
                path = built / "bin" / f"{module}.{ext}"
                if path.is_file():
                    files["bin/" + path.name] = path.read_bytes()
            source = modules.get(module)
            if source and source.parent.parent.parent == ROOT / "applications":
                files["source/" + source.name] = source.read_bytes()
        return files

    for name, (members, assets, commands) in singles.items():
        files = files_for(members)
        for asset in assets:
            path = ROOT / "applications/assets/data" / asset
            if not path.is_file():
                stop("missing application asset: " + str(path))
            files["data/" + asset] = path.read_bytes()
        zip_package(archives / f"{name}.zip",
                    {"name": name, "version": "1", "platform": platform,
                     "requires": [], "commands": commands}, files)
    for group in sorted(groups):
        members = groups[group] - CORE
        if group == "desktop":
            members -= single_modules
        files = files_for(members)
        if group == "desktop":
            for path in (ROOT / "applications/assets/data").iterdir():
                if path.is_file() and path.name not in single_data:
                    files["data/" + path.name] = path.read_bytes()
        if files:
            zip_package(archives / f"{group}.zip",
                        {"name": group, "version": "1", "platform": platform,
                         "requires": sorted(singles) if group == "desktop" else [],
                         "commands": ["StartMenu.Open"] if group == "desktop" else []},
                        files)
    output.mkdir(parents=True)
    for name in ("a2.cfg", "oberon.cfg", "a2.sh", "a2.bat", "oberon", "oberon.exe"):
        path = built / name
        if path.is_file():
            shutil.copy2(path, output / name)
    for folder in ("bin", "data", "source", "work", "apps"):
        (output / folder).mkdir()
    for path in (built / "bin").iterdir():
        if path.is_file() and not any(path.name in (f"{m}.{object_ext}", f"{m}.{symbol_ext}") for m in optional):
            shutil.copy2(path, output / "bin" / path.name)
    core_data = keep_data()
    for name in core_data:
        shutil.copy2(ROOT / "data" / name, output / "data" / name)
    if (built / "source").is_dir():
        for path in (built / "source").iterdir():
            if path.is_file() and path.suffix.lower() == ".mod":
                module = re.search(rb"\bMODULE\s+([A-Za-z][A-Za-z0-9_]*)", path.read_bytes()[:4096])
                if not module or module.group(1).decode("ascii") not in optional:
                    shutil.copy2(path, output / "source" / path.name)
    config = output / "a2.cfg"
    body = config.read_text(encoding="utf-8")
    if "Autostart.Run~" not in body:
        stop("a2.cfg lacks Autostart.Run")
    config.write_text(body.replace("Autostart.Run~", "PET.Open~", 1), encoding="utf-8")
    (output / "minia2-image.json").write_text(json.dumps({"format": FORMAT, "platform": platform}) + "\n", encoding="utf-8")
    refresh_paths(output)
    print(f"minimal image: {output} ({len(core_data)} data files)")
    print(f"installable ZIPs: {archives}")

def pack(args):
    staging = args.staging.resolve()
    manifest = json.loads((staging / "a2app.json").read_text(encoding="utf-8"))
    files = {}
    for folder in ("bin", "data", "source"):
        base = staging / folder
        if base.is_dir():
            for path in base.iterdir():
                if path.is_symlink() or not path.is_file():
                    stop("packages contain only regular flat files")
                files[f"{folder}/{path.name}"] = path.read_bytes()
    zip_package(args.output, manifest, files)
    print(args.output)


def resolve_zip(value, image):
    if value.startswith("https://"):
        request = urllib.request.Request(value, headers={"User-Agent": "minia2-app/1"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.geturl().startswith("https://"):
                stop("HTTPS download redirected to an insecure URL")
            body = response.read(100_000_001)
        if len(body) > 100_000_000:
            stop("download exceeds 100 MB")
        from io import BytesIO
        return BytesIO(body)
    if "://" in value:
        stop("only HTTPS URLs are supported")
    path = Path(value)
    if path.is_file():
        return path
    catalog = ROOT / "applications/packages" / image_platform(image) / f"{value}.zip"
    if catalog.is_file():
        return catalog
    stop("package not found: " + value)


def install(args):
    image = args.image.resolve()
    platform = image_platform(image)
    manifest, files = read_package(resolve_zip(args.package, image), platform)
    name = manifest["name"]
    current = installed(image)
    if name in current:
        stop("already installed: " + name)
    seen = getattr(args, "_seen", set())
    if name in seen:
        stop("package dependency cycle: " + name)
    for dep in manifest.get("requires", []):
        if dep not in current:
            install(argparse.Namespace(image=image, package=dep, _seen=seen | {name}))
    current = installed(image)
    owned = {key for pkg in current.values() for key in pkg["files"]}
    for entry in files:
        if entry in owned or (image / entry).exists():
            stop("package collides with base or another package: " + entry)
    apps = image / "apps"
    target = apps / name
    if target.exists():
        stop("package directory already exists")
    target.mkdir()
    try:
        for entry, body in files.items():
            relative = PurePosixPath(entry)
            destination = target.joinpath(*relative.parts)
            destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(body)
        (target / "a2app.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        refresh_paths(image)
    except Exception:
        shutil.rmtree(target)
        raise
    print(f"installed {name}; restart A2")
    for command in manifest.get("commands", []):
        print("  " + command)


def remove(args):
    image = args.image.resolve()
    current = installed(image)
    if args.name not in current:
        stop("not installed: " + args.name)
    if any(args.name in pkg.get("requires", []) for name, pkg in current.items() if name != args.name):
        stop("another installed package requires this one")
    root = (image / "apps").resolve()
    target = root / args.name
    if target.is_symlink() or target.resolve().parent != root:
        stop("unsafe package directory")
    shutil.rmtree(target)
    refresh_paths(image)
    print(f"removed {args.name}; restart A2")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    p = subs.add_parser("reorganize", help="move application sources and optional data out of source/data")
    p.set_defaults(action=reorganize)
    p = subs.add_parser("build", help="make a minimal image and local application ZIPs")
    p.add_argument("--platform", choices=EXT, required=True)
    p.add_argument("--build", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--packages", type=Path, default=ROOT / "applications/packages")
    p.set_defaults(action=build)
    p = subs.add_parser("pack", help="create a ZIP from a2app.json plus bin/data/source")
    p.add_argument("staging", type=Path)
    p.add_argument("output", type=Path)
    p.set_defaults(action=pack)
    p = subs.add_parser("install", help="install a local catalog ZIP, path, or HTTPS URL")
    p.add_argument("image", type=Path)
    p.add_argument("package")
    p.set_defaults(action=install)
    p = subs.add_parser("remove", help="uninstall an application")
    p.add_argument("image", type=Path)
    p.add_argument("name")
    p.set_defaults(action=remove)
    p = subs.add_parser("list", help="list installed packages")
    p.add_argument("image", type=Path)
    p.set_defaults(action=lambda a: [print(n, m["version"]) for n, m in installed(a.image.resolve()).items()])
    args = parser.parse_args()
    try:
        args.action(args)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    main()
