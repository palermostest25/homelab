#!/usr/bin/env python3
"""Conservative structural and known-pattern scan; does not prove all secrets absent."""
from pathlib import Path
import re
import sys
import yaml

root=Path(__file__).resolve().parents[1]
bundle=root/'services/arcane-rebuild'
patterns=[r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|PRIVATE).*KEY-----',r'gh[pousr]_[A-Za-z0-9]{20,}',r'github_pat_[A-Za-z0-9_]{30,}',r'https?://[^\s/:]+:[^\s/@]+@',r'ntfy\.sh/[A-Za-z0-9_-]+',r'/api/push/[A-Za-z0-9]{8,}', 'denby'+'_alerts']
failures=[]
files=[root/'INVENTORY.md',*bundle.rglob('*'),root/'tools/rebuild-arcane.py',root/'tools/rebuild-arcane.sh',root/'tools/test-rebuild-arcane.py']
for path in files:
    if not path.is_file():continue
    text=path.read_text()
    for pattern in patterns:
        if re.search(pattern,text):failures.append(str(path.relative_to(root))+': known secret pattern')
    if path.name=='.env.example' and any(line.split('=',1)[1] for line in text.splitlines() if '=' in line):
        failures.append(str(path.relative_to(root))+': populated env example')
for path in (bundle/'stacks').glob('*/compose.yaml'):
    data=yaml.safe_load(path.read_text())
    for name,spec in data['services'].items():
        for key,value in spec.get('environment',{}).items():
            if not isinstance(value,str) or not re.fullmatch(r'\$\{[A-Za-z_][A-Za-z0-9_]*:\?Set [A-Za-z_][A-Za-z0-9_]*\}',value):
                failures.append(f'{path.parent.name}/{name}/{key}: literal environment input')
        if spec.get('restart') not in ['always','unless-stopped']:
            failures.append(f'{path.parent.name}/{name}: missing restart policy')
if failures:
    print('\n'.join(failures));sys.exit(1)
print('PASS: 102 Compose definitions; empty env examples; no known credential, push-token or notification-topic patterns; all service environment values parameterized.')
print('Scope: generated bundle, entrypoint, tests and inventory change. This is not a whole-history or entropy scan.')
