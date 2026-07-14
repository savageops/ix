#!/usr/bin/env python3
"""
P30: Binary signing script for IX.

Signs the built binary using platform-native code-signing tools when
credentials are available via environment variables.

Windows:
  IX_SIGN_CERT=<path-to-pfx>  IX_SIGN_PASSWORD=<password>
  → signtool sign /f <cert> /p <pass> /fd SHA256 /tr <timestamp_url> /td SHA256 <exe>

macOS:
  IX_SIGN_IDENTITY=<keychain-identity>
  → codesign --sign <identity> --force --timestamp <binary>

Linux:
  IX_SIGN_KEY=<gpg-key-id>
  → gpg --detach-sign --armor --local-user <key> <binary>

When credentials are absent, prints a notice and exits 0 (unsigned dev build).
This allows CI to gate signing behind secrets without breaking local dev.
"""

import os
import subprocess
import sys
import platform


def sign_windows(exe_path):
    cert = os.environ.get("IX_SIGN_CERT")
    password = os.environ.get("IX_SIGN_PASSWORD")
    if not cert or not password:
        print(f"[sign] IX_SIGN_CERT not set — skipping signing for {exe_path}")
        return False

    timestamp_url = "http://timestamp.sectigo.com"
    cmd = [
        "signtool", "sign",
        "/f", cert,
        "/p", password,
        "/fd", "SHA256",
        "/tr", timestamp_url,
        "/td", "SHA256",
        exe_path,
    ]
    print(f"[sign] Signing {exe_path} with signtool")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[sign] ERROR: signtool failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"[sign] Successfully signed {exe_path}")
    return True


def sign_macos(binary_path):
    identity = os.environ.get("IX_SIGN_IDENTITY")
    if not identity:
        print(f"[sign] IX_SIGN_IDENTITY not set — skipping signing for {binary_path}")
        return False

    cmd = [
        "codesign",
        "--sign", identity,
        "--force",
        "--timestamp",
        binary_path,
    ]
    print(f"[sign] Signing {binary_path} with codesign identity={identity}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[sign] ERROR: codesign failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"[sign] Successfully signed {binary_path}")
    return True


def sign_linux(binary_path):
    key_id = os.environ.get("IX_SIGN_KEY")
    if not key_id:
        print(f"[sign] IX_SIGN_KEY not set — skipping signing for {binary_path}")
        return False

    cmd = [
        "gpg",
        "--detach-sign",
        "--armor",
        "--local-user", key_id,
        "--output", binary_path + ".sig",
        binary_path,
    ]
    print(f"[sign] Signing {binary_path} with GPG key={key_id}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[sign] ERROR: gpg failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"[sign] Successfully signed {binary_path} (signature: {binary_path}.sig)")
    return True


def main():
    # Accept one or more binary paths (Windows: .exe, others: no extension).
    paths = [a for a in sys.argv[1:] if os.path.isfile(a)]
    if not paths:
        print("[sign] No binary files found to sign")
        return

    system = platform.system()
    signed_any = False

    for binary_path in paths:
        if system == "Windows":
            if sign_windows(binary_path):
                signed_any = True
        elif system == "Darwin":
            if sign_macos(binary_path):
                signed_any = True
        else:
            if sign_linux(binary_path):
                signed_any = True

    if signed_any:
        print(f"[sign] Signing complete: {len(paths)} binary(s) processed")
    else:
        print("[sign] No binaries were signed (credentials not available)")


if __name__ == "__main__":
    main()
