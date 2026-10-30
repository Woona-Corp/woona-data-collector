"""Explicit networked lock refresh using preinstalled uv 0.12.24; never deploys.

Run with Python 3.13+; --upgrade NAME releases only that transitive constraint.
Direct pins remain owned by pyproject.toml. Uses temporary files, not the live venv.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

from check_dependency_lock import ROOT, canonical, parse_lock

UV_VERSION = "uv 0.12.24"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upgrade", action="append", default=[], metavar="NAME")
    args = parser.parse_args()
    version = subprocess.check_output(["uv", "--version"], text=True).strip()
    if not version.startswith(UV_VERSION + " ") and version != UV_VERSION:
        raise SystemExit(f"Expected {UV_VERSION}, found {version}; review generator upgrade first")
    unlocked = {canonical(name) for name in args.upgrade}
    runtime = parse_lock((ROOT / "requirements.lock").read_text())
    tests = parse_lock((ROOT / "requirements-test.lock").read_text())
    with tempfile.TemporaryDirectory(prefix="woona-lock-") as temp:
        work = Path(temp)
        constraints = work / "runtime.constraints"
        constraints.write_text("".join(f"{name}=={version}\n" for name, version in runtime.items() if name not in unlocked))
        test_constraints = work / "test.constraints"
        test_constraints.write_text("".join(f"{name}=={version}\n" for name, version in tests.items() if name not in runtime and name not in unlocked))
        outputs = []
        for arch in ("x86_64", "aarch64"):
            for extra in (False, True):
                output = work / f"{arch}-{'test' if extra else 'runtime'}.lock"
                command = ["uv", "--no-config", "pip", "compile", str(ROOT / "pyproject.toml"),
                           "--python-version", "3.13", "--python-platform", f"{arch}-manylinux_2_28",
                           "--only-binary", ":all:", "--generate-hashes", "--no-header", "--no-annotate",
                           "--index-url", "https://pypi.org/simple", "-c", str(constraints), "-o", str(output)]
                if extra:
                    command += ["--extra", "test", "-c", str(work / f"{arch}-runtime.lock"), "-c", str(test_constraints)]
                subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
                outputs.append(output)
        for index in (0, 1):
            if outputs[index].read_bytes() != outputs[index + 2].read_bytes():
                raise SystemExit("Architecture resolutions differ; review platform markers/separate locks before publishing")
            parse_lock(outputs[index].read_text())
        for index, name in ((0, "requirements.lock"), (1, "requirements-test.lock")):
            (ROOT / name).write_bytes(outputs[index].read_bytes())
    subprocess.run([sys.executable, str(ROOT / "check_dependency_lock.py")], check=True)


if __name__ == "__main__":
    main()
