#!/usr/bin/env python3
"""Manage a dedicated, loopback-only nested Proxmox lab; never select a production host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / '.runtime'
NAME = 'proxmox-test-kft'
SSH_PORT = 12222
API_PORT = 18006
ENV = {k: v for k, v in os.environ.items() if k != 'LD_LIBRARY_PATH'}


def run(args, **kwargs):
    return subprocess.run(args, check=True, env=ENV, **kwargs)


def ssh_args():
    return ['ssh', '-i', str(RUNTIME / 'id_ed25519'), '-p', str(SSH_PORT),
            '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
            '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + str(RUNTIME / 'known_hosts'),
            'root@127.0.0.1']


def owned_pid():
    file = RUNTIME / 'qemu.pid'
    if not file.exists():
        return None
    pid = int(file.read_text())
    try:
        cmd = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
    except FileNotFoundError:
        return None
    if not cmd or not cmd[0]:
        return None
    if NAME.encode() not in cmd or Path(f'/proc/{pid}/exe').resolve().name != 'qemu-system-x86_64':
        raise RuntimeError('PID file belongs to another process; refusing to operate')
    return pid


def prepare():
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    RUNTIME.chmod(0o700)
    if (RUNTIME / 'proxmox-test.qcow2').exists():
        raise RuntimeError('Lab disk already exists; prepare will not overwrite it')
    base = RUNTIME / 'debian-13.qcow2'
    url = 'https://cloud.debian.org/images/cloud/trixie/latest/'
    checksums = urllib.request.urlopen(url + 'SHA512SUMS', timeout=30).read().decode()
    checksum = next(line.split()[0] for line in checksums.splitlines()
                    if line.split()[-1].lstrip('*') == 'debian-13-genericcloud-amd64.qcow2')
    if not base.exists() or hashlib.sha512(base.read_bytes()).hexdigest() != checksum:
        urllib.request.urlretrieve(url + 'debian-13-genericcloud-amd64.qcow2', base)
    if hashlib.sha512(base.read_bytes()).hexdigest() != checksum:
        raise RuntimeError('Debian image checksum mismatch')
    (RUNTIME / 'base-sha512').write_text(checksum + '\n')
    if not (RUNTIME / 'id_ed25519').exists():
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(RUNTIME / 'id_ed25519')])
    public_key = (RUNTIME / 'id_ed25519.pub').read_text().strip()
    bootstrap = (ROOT / 'scripts/bootstrap-proxmox.sh').read_text()
    service = '''[Unit]
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/kft-lab-ready
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kft-bootstrap
[Install]
WantedBy=multi-user.target
'''
    # JSON scalar/list serialization also supplies valid YAML; no secret defaults.
    user_data = '#cloud-config\n' + '\n'.join([
        'hostname: pve-test', 'fqdn: pve-test.kft.invalid', 'manage_etc_hosts: false',
        'disable_root: false', 'ssh_pwauth: false',
        'users: ' + json.dumps([{'name': 'root', 'ssh_authorized_keys': [public_key]}]),
        'write_files: ' + json.dumps([
            {'path': '/etc/hosts', 'content': '127.0.0.1 localhost\n10.0.2.15 pve-test.kft.invalid pve-test\n::1 localhost\n'},
            {'path': '/usr/local/sbin/kft-bootstrap', 'permissions': '0700', 'content': bootstrap},
            {'path': '/etc/systemd/system/kft-bootstrap.service', 'permissions': '0644', 'content': service},
        ]),
        'runcmd: ' + json.dumps([['systemctl', 'daemon-reload'], ['systemctl', 'enable', '--now', 'kft-bootstrap.service']]),
    ]) + '\n'
    (RUNTIME / 'user-data').write_text(user_data)
    (RUNTIME / 'meta-data').write_text('instance-id: kft-isolated-lab\nlocal-hostname: pve-test\n')
    run(['xorriso', '-as', 'mkisofs', '-quiet', '-volid', 'cidata', '-joliet', '-rock',
         '-output', str(RUNTIME / 'seed.iso'), str(RUNTIME / 'user-data'), str(RUNTIME / 'meta-data')])
    run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(base),
         str(RUNTIME / 'proxmox-test.qcow2'), '60G'])
    print('Prepared isolated lab. Start it and check bootstrap progress with lab.py status.')


def start():
    if owned_pid():
        print('Dedicated lab is already running')
        return
    if not (RUNTIME / 'proxmox-test.qcow2').exists():
        raise RuntimeError('Run lab.py prepare first')
    if not os.access('/dev/kvm', os.R_OK | os.W_OK):
        raise RuntimeError('KVM access is required; no host configuration is changed automatically')
    for port in (SSH_PORT, API_PORT):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', port))
    (RUNTIME / 'qmp.sock').unlink(missing_ok=True)
    run(['qemu-system-x86_64', '-enable-kvm', '-cpu', 'host', '-smp', '4', '-m', '8192',
         '-name', NAME, '-drive', f'file={RUNTIME / "proxmox-test.qcow2"},format=qcow2,if=virtio',
         '-drive', f'file={RUNTIME / "seed.iso"},media=cdrom,readonly=on',
         '-nic', f'user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:{API_PORT}-:8006',
         '-display', 'none', '-serial', f'file:{RUNTIME / "serial.log"}',
         '-qmp', f'unix:{RUNTIME / "qmp.sock"},server=on,wait=off',
         '-pidfile', str(RUNTIME / 'qemu.pid'), '-daemonize'])
    print(f'Started dedicated lab: API https://127.0.0.1:{API_PORT}; SSH port {SSH_PORT}')


def stop():
    if not owned_pid():
        print('Dedicated lab is already stopped')
        return
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(str(RUNTIME / 'qmp.sock'))
        stream = sock.makefile('rwb')
        stream.readline()
        for command in ('qmp_capabilities', 'system_powerdown'):
            stream.write((json.dumps({'execute': command}) + '\n').encode())
            stream.flush()
            while True:
                reply=json.loads(stream.readline())
                if 'error' in reply: raise RuntimeError(str(reply['error']))
                if 'return' in reply: break
    for _ in range(120):
        if not owned_pid():
            print('Dedicated lab stopped')
            return
        time.sleep(1)
    raise RuntimeError('Graceful shutdown timed out; left VM running, no force kill')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'start', 'stop', 'status', 'ssh', 'snapshot', 'restore'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare()
    elif args.command == 'start':
        start()
    elif args.command == 'stop':
        stop()
    elif args.command in ('snapshot','restore'):
        if owned_pid(): raise RuntimeError('Stop the dedicated lab before changing disk snapshots')
        if len(args.args)!=1 or not args.args[0].replace('-','').replace('_','').isalnum():
            raise RuntimeError('Provide one simple snapshot name')
        flag='-c' if args.command=='snapshot' else '-a'
        run(['qemu-img','snapshot',flag,args.args[0],str(RUNTIME/'proxmox-test.qcow2')])
    elif args.command == 'ssh':
        run(ssh_args() + args.args)
    elif owned_pid():
        run(ssh_args() + ['test -e /var/lib/kft-lab-ready && pveversion || tail -12 /var/log/kft-bootstrap.log'])
    else:
        print('Dedicated lab is stopped')


if __name__ == '__main__':
    main()
