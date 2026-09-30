#!/usr/bin/env python3
"""Restore reviewed Arcane Compose definitions. Default mode is read-only."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'services/arcane-rebuild'

def run(args, quiet=False):
    # Never echo rendered compose, application logs, or environment values.
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} operation failed (exit {result.returncode}); inspect locally, keeping secrets private')
    return result.stdout.strip()

def choose(manifest, names):
    known = {s['name'] for s in manifest['stacks']}
    if set(names) - known:
        raise ValueError('Unknown stack: ' + ', '.join(sorted(set(names) - known)))
    return [s for s in manifest['stacks'] if s['name'] in names] if names else [s for s in manifest['stacks'] if s['enabled'] and not s['exposure_gate']]

def compose(stack, env_file, source=False):
    path = BUNDLE / 'stacks' / stack['name'] / 'compose.yaml' if source else Path(stack['target']) / 'compose.yaml'
    return ['docker', 'compose', '--env-file', str(env_file), '--project-name', stack['name'], '--project-directory', stack['target'], '-f', str(path)]

def check_paths(stacks, docker_missing=False):
    errors = []
    for stack in stacks:
        target = Path(stack['target']) / 'compose.yaml'
        source = BUNDLE / 'stacks' / stack['name'] / 'compose.yaml'
        if target.exists() and target.read_bytes() != source.read_bytes():
            errors.append(f'{target}: existing definition differs; refusing overwrite')
        for item in stack['binds']:
            if item['profiles']: continue  # Optional profiles are not enabled by this entrypoint.
            p = Path(item['path'])
            if docker_missing and item['kind'] == 'socket': continue
            if not p.exists(): errors.append(f'{p}: restore required before deployment')
            elif item['kind'] == 'file' and not p.is_file(): errors.append(f'{p}: expected file')
            elif item['kind'] == 'directory' and not p.is_dir(): errors.append(f'{p}: expected directory')
        for item in stack['env_files']:
            if not Path(item['path']).is_file(): errors.append(f"{item['path']}: restore private application env file")
    if errors: raise ValueError('\n'.join(sorted(set(errors))))

def install_docker():
    if shutil.which('docker'):
        run(['docker', 'compose', 'version'])
        return
    # Fresh Debian 12 only. Never remove conflicting packages or upgrade an existing engine.
    for package in ['docker.io','docker-compose','podman-docker','containerd','runc']:
        r = subprocess.run(['dpkg-query','-W','-f=${Status}',package],capture_output=True,text=True)
        if 'install ok installed' in r.stdout: raise ValueError('Conflicting package: '+package)
    run(['apt-get','update'])
    run(['apt-get','install','-y','ca-certificates','curl'])
    Path('/etc/apt/keyrings').mkdir(mode=0o755,exist_ok=True)
    key=Path('/etc/apt/keyrings/arcane-docker.asc')
    run(['curl','-fsSL','https://download.docker.com/linux/debian/gpg','-o',str(key)])
    key.chmod(0o644)
    arch=run(['dpkg','--print-architecture'])
    Path('/etc/apt/sources.list.d/arcane-docker.sources').write_text(
        f'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: bookworm\nComponents: stable\nArchitectures: {arch}\nSigned-By: {key}\n')
    run(['apt-get','update'])
    run(['apt-get','install','-y','docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin','docker-compose-plugin'])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--check',action='store_true',help='Validate prerequisites and rendered Compose without starting containers')
    parser.add_argument('--env-file',type=Path,default=BUNDLE/'.env')
    parser.add_argument('--stack',action='append',default=[])
    parser.add_argument('--list-inputs',action='store_true')
    parser.add_argument('--exposure-approval',help='Ticket URL recording explicit owner approval for selected tunnel stacks')
    parser.add_argument('--data-restored',action='store_true',help='Confirm private data and named-volume backups have been restored')
    args=parser.parse_args()
    manifest=json.loads((BUNDLE/'manifest.json').read_text());stacks=choose(manifest,args.stack)
    inputs=sorted({k for s in stacks for k in s['required']})
    if args.list_inputs:
        print('\n'.join(inputs));return
    print('Selected stacks: '+', '.join(s['name'] for s in stacks))
    print('Required input names: '+', '.join(inputs))
    print('Excluded unless explicitly selected: stopped/untracked projects and cloudflared/playit/twingate.')
    if not (args.apply or args.check):
        print('PLAN ONLY. Restore private inputs and data; use --check before --apply --data-restored.');return
    if any(s['exposure_gate'] for s in stacks) and not args.exposure_approval:
        raise ValueError('Tunnel deployment requires the owner approval ticket via --exposure-approval')
    if not args.env_file.is_file(): raise ValueError('Missing private --env-file; copy .env.example and populate it locally')
    if args.env_file.stat().st_mode & 0o077: raise ValueError('Private --env-file must have mode 0600')
    missing_docker=not shutil.which('docker')
    check_paths(stacks,missing_docker)
    if args.apply:
        if os.geteuid()!=0: raise ValueError('--apply requires root on the fresh target host')
        release=Path('/etc/os-release').read_text()
        if 'ID=debian' not in release or 'VERSION_ID="12"' not in release: raise ValueError('Only Debian 12 is supported')
        if not args.data_restored: raise ValueError('Restore data first and pass --data-restored')
        marker=Path('/opt/docker/.arcane-rebuild-managed')
        if not marker.exists() and not missing_docker and run(['docker','ps','-aq']):
            raise ValueError('Existing Docker containers detected; refusing to adopt a working host')
        install_docker()
    elif missing_docker:
        raise ValueError('--check needs Docker Compose installed; plan mode does not')
    # Validate all definitions before creating any container. Output may contain secrets, so suppress it.
    for stack in stacks: run(compose(stack,args.env_file,source=True)+['config','--quiet'])
    if args.check and not args.apply:
        print('PASS: selected Compose definitions and restore path prerequisites');return
    run(['systemctl','enable','--now','docker'])
    for stack in stacks:
        target=Path(stack['target']);target.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(BUNDLE/'stacks'/stack['name']/'compose.yaml',target/'compose.yaml')
    marker.write_text('Managed by homelab tools/rebuild-arcane.sh\n')
    for stack in stacks:
        run(compose(stack,args.env_file)+['up','-d','--wait','--wait-timeout','180'])
        print('Started and passed Compose readiness: '+stack['name'])
    print('Complete: Compose readiness only. Application checks and Sentry cold-boot verification remain required.')

if __name__=='__main__':
    try: main()
    except (ValueError,RuntimeError,OSError) as exc:
        print('STOP: '+str(exc),file=sys.stderr);sys.exit(1)
