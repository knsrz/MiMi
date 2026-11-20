#!/usr/bin/env python3
"""Validate the appcast and verify its archive against the public key embedded in the app."""
import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

assets = pathlib.Path(sys.argv[1]).resolve()
project = pathlib.Path(__file__).resolve().parent.parent
info = plistlib.loads((project / 'Resources/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
feed = assets / 'appcast.xml'
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Release feed must have one current version'
item = items[0]
assert item.findtext(sparkle + 'version') == info['CFBundleVersion']
assert item.findtext(sparkle + 'shortVersionString') == version
assert item.findtext(sparkle + 'minimumSystemVersion') == info['LSMinimumSystemVersion']
enclosure = item.find('enclosure')
archive = assets / f'MiMi-{version}-universal.zip'
assert enclosure.attrib['url'] == f'https://github.com/knsrz/MiMi/releases/download/v{version}/{archive.name}'
assert int(enclosure.attrib['length']) == archive.stat().st_size
signature = enclosure.attrib[sparkle + 'edSignature']
assert len(base64.b64decode(signature)) == 64
# Independent public-key verification catches mismatched CI secrets before publishing.
with tempfile.TemporaryDirectory(prefix='MiMi-release-check-') as temp:
    verifier = pathlib.Path(temp) / 'verify.swift'
    verifier.write_text('''import CryptoKit
import Foundation
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
let signature = Data(base64Encoded: CommandLine.arguments[2])!
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
guard key.isValidSignature(signature, for: payload) else { exit(1) }
''')
    subprocess.run(['xcrun', 'swift', '-sdk', subprocess.check_output([str(project / 'scripts/sdk.sh')], text=True).strip(),
                    str(verifier), info['SUPublicEDKey'], signature, str(archive)], check=True)
    subprocess.run(['ditto', '-x', '-k', str(archive), temp], check=True)
    app = pathlib.Path(temp) / 'MiMi.app'
    packaged = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert packaged == info, 'Archive and source versions/configuration must match'
    binary = app / 'Contents/MacOS/Inkfolio'
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    assert set(architectures) == {'arm64', 'x86_64'}
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'Validated MiMi {version}: universal binary, bundle, feed, URL, size and EdDSA archive signature.')
