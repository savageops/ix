#!/usr/bin/env python3
"""
P30: Binary signing script for IX.

Supports two signing methods:

1. Sigstore (cosign) — keyless signing via GitHub OIDC. This is the
   default in CI. Produces a short-term Fulcio CA certificate that is
   verifiable via `cosign verify-blob`. Trusted by the Sigstore public
   good trust root (used by Kubernetes, nginx, etc.).

   IX_SIGN_METHOD=sigstore
   → cosign sign-blob --yes --output-certificate cert.pem \
       --output-signature sig.bin <binary>

2. Platform-native signing (self-signed or CA-issued):
   Windows: IX_SIGN_CERT=<PFX> IX_SIGN_PASSWORD=<pass>
   → signtool sign /f <cert> /p <pass> /fd SHA256 <exe>
   macOS: IX_SIGN_IDENTITY=<identity>
   → codesign --sign <identity> --force <binary>
   Linux: IX_SIGN_KEY=<GPG key>
   → gpg --detach-sign --armor --local-user <key> <binary>

When no signing method is configured, prints a notice and exits 0
(unsigned dev build).
"""

import os
import subprocess
import sys
import platform


def sign_sigstore(binary_path):
    """Sign using Sigstore cosign keyless (OIDC). Works on all platforms."""
    cosign_cmd = _find_cosign()
    if not cosign_cmd:
        print(f"[sign] cosign not found — skipping Sigstore signing for {binary_path}")
        return False

    cert_path = binary_path + ".pem"
    sig_path = binary_path + ".sig"
    cmd = [
        cosign_cmd, "sign-blob",
        "--yes",
        "--output-certificate", cert_path,
        "--output-signature", sig_path,
        binary_path,
    ]
    print(f"[sign] Signing {binary_path} with Sigstore (cosign keyless)")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[sign] ERROR: cosign failed: {result.stderr}", file=sys.stderr)
        return False
    print(f"[sign] Successfully signed {binary_path} (Sigstore)")
    print(f"[sign]   Certificate: {cert_path}")
    print(f"[sign]   Signature:   {sig_path}")
    print(f"[sign]   Verify: cosign verify-blob --certificate {cert_path} --signature {sig_path} {binary_path}")
    return True


def sign_windows(exe_path):
    cert = os.environ.get("IX_SIGN_CERT")
    password = os.environ.get("IX_SIGN_PASSWORD")
    if not cert or not password:
        print(f"[sign] IX_SIGN_CERT not set — skipping Authenticode signing for {exe_path}")
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
        return False
    print(f"[sign] Successfully signed {exe_path}")
    return True


def sign_macos(binary_path):
    identity = os.environ.get("IX_SIGN_IDENTITY")
    if not identity:
        print(f"[sign] IX_SIGN_IDENTITY not set — skipping codesign for {binary_path}")
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
        return False
    print(f"[sign] Successfully signed {binary_path}")
    return True


def sign_linux(binary_path):
    key_id = os.environ.get("IX_SIGN_KEY")
    if not key_id:
        print(f"[sign] IX_SIGN_KEY not set — skipping GPG for {binary_path}")
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
        return False
    print(f"[sign] Successfully signed {binary_path} (signature: {binary_path}.sig)")
    return True


def _which(cmd):
    """Check if a command is available in PATH."""
    try:
        subprocess.run([cmd, "--version"], capture_output=True, check=True)
        return True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return False


def _find_cosign():
    """Find cosign binary — checks PATH, COSIGN_PATH env, and common locations."""
    # Check COSIGN_PATH env var (set by cosign-installer in some setups).
    env_path = os.environ.get("COSIGN_PATH")
    if env_path and os.path.isfile(env_path):
        return env_path
    # Check HOME/.cosign (cosign-installer default).
    home = os.environ.get("HOME", "")
    if home:
        for candidate in ["{}/.cosign/cosign".format(home), "{}/.cosign/bin/cosign".format(home)]:
            if os.path.isfile(candidate):
                return candidate
    # Check PATH.
    if _which("cosign"):
        return "cosign"
    return None


def main():
    paths = [a for a in sys.argv[1:] if os.path.isfile(a)]
    if not paths:
        print("[sign] No binary files found to sign")
        return

    sign_method = os.environ.get("IX_SIGN_METHOD", "auto")
    system = platform.system()
    signed_any = False

    for binary_path in paths:
        # Determine signing method.
        if sign_method == "sigstore":
            if sign_sigstore(binary_path):
                signed_any = True
        elif sign_method == "auto":
            # Try Sigstore first (cross-platform, trusted).
            if _find_cosign():
                if sign_sigstore(binary_path):
                    signed_any = True
                    continue
            # Fall back to platform-native.
            if system == "Windows":
                if sign_windows(binary_path):
                    signed_any = True
            elif system == "Darwin":
                if sign_macos(binary_path):
                    signed_any = True
            else:
                if sign_linux(binary_path):
                    signed_any = True
        else:
            # Explicit platform method.
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
        print("[sign] To enable signing:")
        print("[sign]   Sigstore: install cosign, set IX_SIGN_METHOD=sigstore")
        print("[sign]   Windows:  set IX_SIGN_CERT and IX_SIGN_PASSWORD")
        print("[sign]   macOS:    set IX_SIGN_IDENTITY")
        print("[sign]   Linux:    set IX_SIGN_KEY")


if __name__ == "__main__":
    main()
