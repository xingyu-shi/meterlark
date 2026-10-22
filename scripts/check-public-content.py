#!/usr/bin/env python3
"""Check publishable source for private metadata and obsolete product identities."""

import ipaddress
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


PUBLIC_HOSTS = {
    "github.com", "raw.githubusercontent.com", "img.shields.io",
    "www.w3.org", "www.apple.com",
}
LEGACY_NAME = re.compile(r"ccusage[ _-]?monitor|ccusage-menubar", re.IGNORECASE)
SECRET_PATTERNS = {
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    "provider credential": re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{32,}\b"),
    "AWS credential": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}


def reserved_host(host):
    return host in {"example.com", "example.net", "example.org", "localhost"} or host.endswith(
        (".example", ".test", ".invalid", ".example.com", ".example.net", ".example.org")
    )


def check(root):
    if (root / ".git").exists():
        names = subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
        ).decode().split("\0")
        paths = [root / name for name in sorted(set(names)) if name]
    else:
        paths = sorted(root.rglob("*"))
    issues = []
    checked = 0
    for path in paths:
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        if relative == "scripts/check-public-content.py":
            # This file necessarily contains the patterns being prohibited.
            continue
        data = path.read_bytes()
        if b"\0" in data:
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        checked += 1
        for number, line in enumerate(text.splitlines(), 1):
            reasons = []
            if LEGACY_NAME.search(line):
                reasons.append("obsolete product identity")
            for label, pattern in SECRET_PATTERNS.items():
                if pattern.search(line):
                    reasons.append(label)
            if re.search(r"/Users/[^/\s\"']+/|[A-Z]:\\Users\\[^\\\s]+", line):
                reasons.append("local user path")
            if re.search(r"[A-Za-z0-9._%+-]+@(?![^\s@]*example\.(?:com|net|org)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}", line):
                reasons.append("email address")
            for value in re.findall(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", line):
                try:
                    address = ipaddress.ip_address(value)
                except ValueError:
                    continue
                documentation = any(address in ipaddress.ip_network(net) for net in (
                    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"
                ))
                if address.is_private and not address.is_loopback and not documentation:
                    reasons.append("private IP address")
            for url in re.findall(r"https?://[A-Za-z0-9_.:-]+", line):
                host = urlsplit(url).hostname or ""
                if host and host not in PUBLIC_HOSTS and not reserved_host(host):
                    reasons.append("unapproved URL host")
            if reasons:
                issues.append(f"{relative}:{number}: {', '.join(sorted(set(reasons)))}")
    for issue in issues:
        print(issue)
    print(f"Public content check: {checked} text files, {len(issues)} findings.")
    return bool(issues)


if __name__ == "__main__":
    sys.exit(check(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()))
