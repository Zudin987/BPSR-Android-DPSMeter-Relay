from pathlib import Path

p = Path('.github/scripts/apply_uiux.py')
s = p.read_text(encoding='utf-8')
old = '''    "            ' -ProfilePath ' + (Quote-Argument $AndroidConfig) + ' -LifetimeSeconds ' + $ShareLifetimeSeconds",'''
new = '''    "            ' -ProfilePath ' + (Quote-Argument $AndroidConfig) +\\n            ' -LifetimeSeconds ' + $ShareLifetimeSeconds",'''
count = s.count(old)
if count != 1:
    raise SystemExit(f'expected one share-anchor source literal, found {count}')
p.write_text(s.replace(old, new, 1), encoding='utf-8', newline='\n')
