import subprocess
import sys

from .installer import ensure_executable


def main() -> int:
    executable = ensure_executable()
    completed = subprocess.run([str(executable), *sys.argv[1:]], check=False)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
