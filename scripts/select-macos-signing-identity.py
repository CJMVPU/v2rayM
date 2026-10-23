#!/usr/bin/env python3
"""Select a usable code-signing certificate by its actual subject OU (team)."""
import argparse
import re
import subprocess
import sys


def select_identity(team, identities, certificates, inspect):
    valid = {value.upper() for value in re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"', identities, re.M)}
    if not valid:
        raise RuntimeError('系统未列出可用代码签名身份。请在本机终端运行 security find-identity -v -p codesigning 检查证书及私钥状态。')
    for certificate in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', certificates, re.S):
        details = inspect(certificate)
        fingerprint = re.search(r'(?im)^sha1 Fingerprint=([A-Fa-f0-9:]+)\s*$', details)
        units = re.findall(r'(?m)^\s*OU\s*=\s*(.*?)\s*$', details)
        if fingerprint and team in units:
            identity = fingerprint.group(1).replace(':', '').upper()
            if identity in valid:
                return identity
    raise RuntimeError('存在可用签名身份，但没有匹配团队 ' + team + ' 的证书。未替换应用。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('team')
    args = parser.parse_args()
    identities = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    certificates = subprocess.check_output(['/usr/bin/security', 'find-certificate', '-a', '-p'], text=True)
    def inspect(certificate):
        return subprocess.check_output(['/usr/bin/openssl', 'x509', '-noout', '-fingerprint', '-sha1',
                                        '-subject', '-nameopt', 'sep_multiline,utf8'], input=certificate, text=True)
    try:
        print(select_identity(args.team, identities, certificates, inspect))
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
