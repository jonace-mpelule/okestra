#!/usr/bin/env python3
"""Install official, checksum-verified toolchains as the Okestra service user."""
import hashlib
import json
import os
import re
import sys
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path('/var/lib/okestra')
FLUTTER_RELEASES_URL = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json'

def fetch(url, destination):
    if urllib.parse.urlparse(url).scheme != 'https':
        raise RuntimeError('Only HTTPS downloads are supported')
    last = None
    for _ in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response, destination.open('wb') as out:
                if urllib.parse.urlparse(response.url).scheme != 'https':
                    raise RuntimeError('Unsafe download redirect')
                shutil.copyfileobj(response, out, 1024*1024)
            return
        except (OSError, TimeoutError) as error:
            last = error
    raise RuntimeError(f'Download failed: {url}: {last}')

def verify(path, algorithm, expected):
    if algorithm not in ('sha1', 'sha256') or not expected:
        raise RuntimeError('Missing or unsupported official checksum')
    digest = hashlib.new(algorithm)
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            digest.update(chunk)
    if digest.hexdigest().lower() != expected.strip().lower():
        raise RuntimeError(f'Checksum mismatch: {path.name}')

def stable_flutter(metadata):
    current = metadata['current_release']['stable']
    candidates = [r for r in metadata['releases'] if r['hash'] == current and r.get('dart_sdk_arch','x64') == 'x64']
    if not candidates:
        raise RuntimeError('No stable Flutter x64 archive in official metadata')
    release = candidates[0]
    path = release['archive']
    if not path.startswith('stable/linux/') or '..' in path:
        raise RuntimeError('Invalid Flutter archive path')
    return 'https://storage.googleapis.com/flutter_infra_release/releases/' + path, release['sha256']

def command_tools(metadata):
    root = ET.fromstring(metadata)
    def tag(element): return element.tag.rsplit('}',1)[-1]
    def children(element, name): return [c for c in element if tag(c) == name]
    def child(element, name):
        values=children(element,name)
        return values[0] if values else None
    candidates=[]
    for package in root.iter():
        if tag(package) != 'remotePackage' or not package.get('path','').startswith('cmdline-tools;'):
            continue
        channel=child(package,'channelRef')
        if channel is not None and channel.get('ref') != 'channel-0': continue
        revision=child(package,'revision')
        version=tuple(int((child(revision,k).text if child(revision,k) is not None else '0')) for k in ('major','minor','micro'))
        archives=child(package,'archives')
        if archives is None: continue
        for archive in children(archives,'archive'):
            host=child(archive,'host-os')
            if host is None or host.text != 'linux': continue
            complete=child(archive,'complete')
            if complete is None: continue
            url=child(complete,'url').text
            checksum=child(complete,'checksum')
            if not url.startswith('commandlinetools-linux-') or '/' in url or '..' in url:
                raise RuntimeError('Invalid command-line tools archive URL')
            candidates.append((version,url,checksum.get('type','sha1'),checksum.text))
    if not candidates: raise RuntimeError('No stable Linux command-line tools archive found')
    _,url,algorithm,digest=max(candidates)
    return 'https://dl.google.com/android/repository/'+url,algorithm,digest

def unzip_checked(archive,destination):
    with zipfile.ZipFile(archive) as data:
        for member in data.infolist():
            path=Path(member.filename)
            if path.is_absolute() or '..' in path.parts or (member.external_attr >> 16) & 0o170000 == 0o120000:
                raise RuntimeError('Unsafe SDK archive entry')
        data.extractall(destination)
    # zipfile intentionally does not restore executable Unix permissions.
    for file in destination.rglob('*'):
        if file.is_file() and ('bin' in file.parts or file.name.endswith('.sh')):
            file.chmod(0o755)

def node_release(metadata):
    for release in metadata:
        version=release.get('version','')
        if release.get('lts') and 'linux-x64' in release.get('files',[]) and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',version):
            return version, f'node-{version}-linux-x64.tar.xz'
    raise RuntimeError('No Linux x64 Node LTS in official metadata')

def install_node(stage):
    destination=ROOT/'node'
    if (destination/'bin/node').is_file(): return
    if destination.exists(): raise RuntimeError('Incomplete managed Node directory; move it aside before retrying')
    fetch('https://nodejs.org/dist/index.json',stage/'node.json')
    version,archive=node_release(json.loads((stage/'node.json').read_text()))
    base=f'https://nodejs.org/dist/{version}/'
    fetch(base+'SHASUMS256.txt',stage/'node-sums')
    expected=None
    for line in (stage/'node-sums').read_text().splitlines():
        fields=line.split()
        if len(fields)==2 and fields[1]==archive: expected=fields[0]
    if not expected: raise RuntimeError('Official Node archive checksum missing')
    print('Downloading verified Node LTS (includes npm)…',flush=True)
    fetch(base+archive,stage/'node.tar.xz');verify(stage/'node.tar.xz','sha256',expected)
    if not hasattr(tarfile,'data_filter'): raise RuntimeError('Python safe tar extraction support is required')
    with tarfile.open(stage/'node.tar.xz') as data: data.extractall(stage,filter='data')
    extracted=stage/archive.removesuffix('.tar.xz')
    if not (extracted/'bin/node').is_file(): raise RuntimeError('Invalid Node archive')
    extracted.rename(destination)

def install():
    if os.geteuid() == 0:
        raise RuntimeError('Run this helper as the okestra service user')
    with tempfile.TemporaryDirectory(prefix='android-install-',dir=ROOT) as staging:
        stage=Path(staging)
        install_node(stage)
        if '--node-only' in sys.argv: return
        flutter=ROOT/'flutter'
        if not (flutter/'bin/flutter').is_file():
            if flutter.exists(): raise RuntimeError('Incomplete Flutter directory exists; move it aside before retrying')
            fetch(FLUTTER_RELEASES_URL,stage/'flutter.json')
            url,digest=stable_flutter(json.loads((stage/'flutter.json').read_text()))
            print('Downloading verified Flutter stable…',flush=True)
            fetch(url,stage/'flutter.tar.xz');verify(stage/'flutter.tar.xz','sha256',digest)
            if not hasattr(tarfile,'data_filter'): raise RuntimeError('Python with tarfile.data_filter support is required (Ubuntu 24.04 or later)')
            with tarfile.open(stage/'flutter.tar.xz') as data: data.extractall(stage,filter='data')
            if not (stage/'flutter/bin/flutter').is_file(): raise RuntimeError('Invalid Flutter archive')
            (stage/'flutter').rename(flutter)
        sdk=ROOT/'android-sdk'
        latest=sdk/'cmdline-tools/latest'
        if not (latest/'bin/sdkmanager').is_file():
            if latest.exists(): raise RuntimeError('Incomplete command-line tools directory; move it aside before retrying')
            fetch('https://dl.google.com/android/repository/repository2-1.xml',stage/'sdk.xml')
            url,algorithm,digest=command_tools((stage/'sdk.xml').read_bytes())
            print('Downloading verified Android command-line tools…',flush=True)
            fetch(url,stage/'sdk.zip');verify(stage/'sdk.zip',algorithm,digest)
            unzip_checked(stage/'sdk.zip',stage/'sdk')
            latest.parent.mkdir(parents=True,exist_ok=True)
            (stage/'sdk/cmdline-tools').rename(latest)
    print('Toolchains installed; continuing SDK setup.',flush=True)

if __name__ == '__main__':
    try: install()
    except Exception as error: raise SystemExit(f'Android tools setup: {error}')
