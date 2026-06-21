"""
Build script for the DR Agent Lambda package.
Run by Terraform null_resource before archive_file zips the package/.
Cross-platform: works on Windows, macOS, and Linux.
"""

import os
import shutil
import subprocess
import sys

PACKAGE_DIR = os.path.join(os.path.dirname(__file__), "package")
SOURCE_FILES = ["agent.py", "tools.py"]

os.makedirs(PACKAGE_DIR, exist_ok=True)

print("Installing Python dependencies into package/...")
subprocess.run(
    [sys.executable, "-m", "pip", "install", "-r", "requirements.txt",
     "-t", PACKAGE_DIR, "--quiet", "--upgrade"],
    check=True,
)

print("Copying source files into package/...")
for fname in SOURCE_FILES:
    src = os.path.join(os.path.dirname(__file__), fname)
    dst = os.path.join(PACKAGE_DIR, fname)
    shutil.copy2(src, dst)
    print(f"  copied {fname}")

print("Lambda package build complete.")
