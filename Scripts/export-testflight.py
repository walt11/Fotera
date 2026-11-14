#!/usr/bin/env python3
"""Export a signed TestFlight IPA, with an opt-in Xcode account-index workaround.

The workaround reuses an already signed-in account. It never reads or stores a
password/token. Xcode 27.2 can migrate a username reference to an unreadable
Keychain identifier; the username workaround can help while the saved token remains accessible.
Use API-key authentication if Xcode reports a missing saved token.
"""
import argparse
import pathlib
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=pathlib.Path)
parser.add_argument('destination', type=pathlib.Path)
parser.add_argument('--apple-id', help='Existing signed-in Apple account; repairs its empty/single-account index')
parser.add_argument('--key-path', type=pathlib.Path, help='App Store Connect API private key file (never copied into the project)')
parser.add_argument('--key-id', help='App Store Connect API Key ID')
parser.add_argument('--issuer-id', help='App Store Connect API Issuer ID')
args = parser.parse_args()
api_values = (args.key_path, args.key_id, args.issuer_id)
if any(api_values) and not all(api_values):
    parser.error('--key-path, --key-id and --issuer-id must be supplied together')
if args.key_path and args.apple_id:
    parser.error('Choose API-key authentication or the saved-account workaround, not both')
if args.key_path and not args.key_path.is_file():
    parser.error('API key file does not exist')
authentication = (['-authenticationKeyPath', str(args.key_path.resolve()),
                   '-authenticationKeyID', args.key_id, '-authenticationKeyIssuerID', args.issuer_id]
                  if args.key_path else [])
root = pathlib.Path(__file__).resolve().parent.parent
key = 'DVTDeveloperAccountManagerAppleIDLists'
domain = 'com.apple.dt.Xcode'
repair = None

def write_index(value):
    # Import a one-key plist: defaults import merges it, preserving other settings.
    subprocess.run(['defaults', 'import', domain, '-'], input=plistlib.dumps({key: value}), check=True)

if args.apple_id:
    prefs = plistlib.loads(subprocess.check_output(['defaults', 'export', domain, '-']))
    repair = prefs.get(key, {}).copy()
    accounts = repair.get('IDE.Identifiers.Prod', [])
    identifier_only = len(accounts) == 1 and isinstance(accounts[0], dict) and set(accounts[0]) == {'identifier'}
    if accounts and accounts != [{'username': args.apple_id}] and not identifier_only:
        sys.exit('Account index contains multiple or conflicting named references. Refusing to replace them. Export without --apple-id or review Xcode accounts first.')
    repair['IDE.Identifiers.Prod'] = [{'username': args.apple_id}]
    write_index(repair)

try:
    result = subprocess.run([
        'xcodebuild', '-exportArchive', '-archivePath', str(args.archive.resolve()),
        '-exportPath', str(args.destination.resolve()),
        '-exportOptionsPlist', str(root / 'ExportOptions-TestFlight.plist'),
        '-allowProvisioningUpdates',
    ] + authentication, cwd=root)
finally:
    if repair is not None:
        # Xcode may replace this reference during export, even on failure.
        write_index(repair)
sys.exit(result.returncode)
