#!/usr/bin/env python3
"""Provision and test KFT services only in lab.py's dedicated local Proxmox VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import time
import re
import urllib.error
import urllib.request

import lab
import bcrypt


def ssh(command, **kwargs):
    return lab.run(lab.ssh_args() + [command], text=True, **kwargs)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,default=lab.ROOT.parent/'KFT-Infra')
    parser.add_argument('--configure-only',action='store_true')
    args=parser.parse_args()
    repo=args.repo.resolve()
    if not (repo/'terraform/test/main.tf').exists(): raise RuntimeError('KFT-Infra isolated test root is required')
    # Verify identity and bootstrap completion before any provisioning or guest mutation.
    check=ssh('test "$(hostname -s)" = pve-test && test -e /var/lib/kft-lab-ready && echo READY',capture_output=True)
    if check.stdout.strip()!='READY': raise RuntimeError('Dedicated local lab is not ready')
    creds=json.loads(ssh('cat /root/kft-test-token.json',capture_output=True).stdout)
    template=ssh('cat /root/kft-test-template',capture_output=True).stdout.strip()
    env=dict(lab.ENV,PROXMOX_VE_API_TOKEN=creds['full-tokenid']+'='+creds['value'])
    tools=repo/'.tools'
    virtual=repo/'.venv/bin'
    env['PATH']=str(virtual)+':'+str(tools)+':'+env['PATH']
    env['ANSIBLE_CONFIG']=str(repo/'ansible/ansible.cfg')
    env['ANSIBLE_COLLECTIONS_PATH']=str(tools/'collections') if (tools/'collections').exists() else env.get('ANSIBLE_COLLECTIONS_PATH',str(Path.home()/'.ansible/collections'))
    def run(command,**kwargs):return subprocess.run(command,cwd=repo,env=env,check=True,**kwargs)
    if not args.configure_only:
        run(['terraform','-chdir=terraform/test','init','-input=false'])
        run(['terraform','-chdir=terraform/test','plan','-input=false','-var=template_file_id='+template,'-out=test.tfplan'])
        run(['terraform','-chdir=terraform/test','apply','-input=false','test.tfplan'])
    services=json.loads(run(['terraform','-chdir=terraform/test','output','-json','services'],capture_output=True,text=True).stdout)
    for name,guest in services.items():
        if not 901 <= guest['id'] <= 905 or not guest['address'].startswith('10.73.0.'):
            raise RuntimeError('Unexpected guest outside the dedicated test namespace')
    # Only the public key is installed on the disposable guests.
    public_key=(lab.RUNTIME/'id_ed25519.pub').read_text()
    for name,guest in services.items():
        status=ssh(f"pct status {guest['id']}",capture_output=True).stdout.strip()
        if status=='status: stopped': ssh(f"pct start {guest['id']}")
        ssh(shlex.join(['pct','exec',str(guest['id']),'--','sh','-c',
            'apt-get update && apt-get install -y openssh-server python3 && install -d -m 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && systemctl enable --now ssh']),input=public_key)
    proxy=shlex.join(lab.ssh_args()[:-1]+['-W','%h:%p',lab.ssh_args()[-1]])
    common=shlex.join(['-o','StrictHostKeyChecking=accept-new','-o','UserKnownHostsFile='+str(lab.RUNTIME/'known_hosts'),'-o','ProxyCommand='+proxy])
    inventory={'all':{'vars':{'ansible_user':'root','ansible_ssh_private_key_file':str(lab.RUNTIME/'id_ed25519'),'ansible_ssh_common_args':common,'ansible_python_interpreter':'/usr/bin/python3','node_exporter_targets':[v['address']+':9100' for v in services.values()]},'children':{'containers':{'hosts':{name:{'ansible_host':guest['address']} for name,guest in services.items()}}}}}
    inventory_path=lab.RUNTIME/'inventory.yml'
    inventory_path.write_text(json.dumps(inventory,indent=2))
    variables=lab.RUNTIME/'variables.json'
    if not variables.exists():
        adguard_password=secrets.token_urlsafe(24)
        variables.write_text(json.dumps({'adguard_test_password':adguard_password,'grafana_admin_password':secrets.token_urlsafe(32),'adguard_password_hash':bcrypt.hashpw(adguard_password.encode(),bcrypt.gensalt()).decode(),'homeassistant_image':'ghcr.io/home-assistant/home-assistant:2026.9.4','homarr_image':'ghcr.io/homarr-labs/homarr:v2.0.0','homarr_encryption_key':secrets.token_hex(32),'homarr_bind_address':'0.0.0.0'}))
        variables.chmod(0o600)
    command=['ansible-playbook','-i',str(inventory_path),'ansible/playbooks/site.yml','-e','@'+str(variables)]
    with (lab.RUNTIME/'ansible-first.log').open('w') as log:
        run(command,stdout=log,stderr=subprocess.STDOUT)
    print('First configuration run completed. Re-running for idempotence.')
    with (lab.RUNTIME/'ansible-second.log').open('w') as log:
        run(command,stdout=log,stderr=subprocess.STDOUT)
    recap=(lab.RUNTIME/'ansible-second.log').read_text()
    changed=re.findall(r'^\S+\s+:.*?changed=(\d+).*?unreachable=(\d+).*?failed=(\d+)',recap,re.M)
    if len(changed)!=5 or any(tuple(map(int,row))!=(0,0,0) for row in changed):
        raise RuntimeError('Second configuration run was not idempotent; inspect ansible-second.log')
    result={'services':services,'checks':{},'idempotence':'five hosts: changed=0, unreachable=0, failed=0'}
    for name,guest in services.items():
        url={'homeassistant':'http://127.0.0.1:8123','adguard':'http://127.0.0.1:3000','homarr':'http://127.0.0.1:7575','grafana':'http://127.0.0.1:3000/api/health','prometheus':'http://127.0.0.1:9090/-/ready'}[name]
        command=shlex.join(['pct','exec',str(guest['id']),'--','curl','-sS','--max-time','10','-o','/dev/null','-w','%{http_code}',url])
        for attempt in range(30):
            response=subprocess.run(lab.ssh_args()+[command],env=lab.ENV,text=True,capture_output=True,timeout=30).stdout.strip()
            if response.isdigit() and 200<=int(response)<400:break
            time.sleep(2)
        result['checks'][name]={'http':response}
        if not response.isdigit() or not 200<=int(response)<400:raise RuntimeError(name+' smoke test failed')
    request_script=r"""
import base64,json,sys,urllib.request,urllib.error
p=json.load(sys.stdin)
request=urllib.request.Request(p['url'])
if 'password' in p:
    auth=base64.b64encode((p.get('user','admin')+':'+p['password']).encode()).decode()
    request.add_header('Authorization','Basic '+auth)
try:
    with urllib.request.urlopen(request,timeout=15) as response:
        print(json.dumps({'http':response.status,'data':json.load(response)}))
except urllib.error.HTTPError as e: print(json.dumps({'http':e.code}))
"""
    def api(id,url,**kwargs):
        command=shlex.join(['pct','exec',str(id),'--','python3','-c',request_script])
        response=ssh(command,input=json.dumps(dict(url=url,**kwargs)),capture_output=True)
        return json.loads(response.stdout)
    private=json.loads(variables.read_text())
    adguard=api(902,'http://127.0.0.1:3000/control/status',password=private['adguard_test_password'])
    if adguard.get('http')!=200:raise RuntimeError('AdGuard generated-credential authentication failed')
    result['checks']['adguard']['authenticated_status']=adguard['http']
    dns=ssh(shlex.join(['pct','exec','902','--','dig','@127.0.0.1','example.com','+short','+time=5','+tries=1']),capture_output=True).stdout.strip()
    if not dns or dns.startswith(';;'):raise RuntimeError('AdGuard DNS resolution failed')
    result['checks']['adguard']['dns']='example.com resolved through the test AdGuard service'
    for path in ['/api/user','/api/datasources/uid/prometheus/health','/api/dashboards/uid/rYdddlPWk']:
        response=api(904,'http://127.0.0.1:3000'+path,password=private['grafana_admin_password'])
        if response.get('http')!=200:raise RuntimeError('Grafana generated-credential/API check failed: '+path)
        if 'dashboards' in path and '000000001' in json.dumps(response.get('data',{})):
            raise RuntimeError('Dashboard still refers to the upstream datasource UID')
        result['checks']['grafana'][path]=response['http']
    for attempt in range(30):
        response=api(905,'http://127.0.0.1:9090/api/v1/targets')
        targets=response.get('data',{}).get('data',{}).get('activeTargets',[])
        if len(targets)==6 and all(t['health']=='up' for t in targets):break
        time.sleep(2)
    if len(targets)!=6 or not all(t['health']=='up' for t in targets):raise RuntimeError('Prometheus has missing/down test scrape targets')
    result['checks']['prometheus']['scrape_targets']='all six targets up: five Node Exporters and Prometheus'
    (lab.RUNTIME/'integration-results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('All five test services answered HTTP successfully. Evidence is in .runtime/.')


if __name__=='__main__':main()
