import os
import glob
import re

routes_dir = "app/api/routes"
files = glob.glob(os.path.join(routes_dir, "*.py"))

def fix_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    changed = False

    # Match: if album is None or album.owner_id != current_user.id:
    # also target.owner_id != current_user.id
    pattern = re.compile(r'if (\w+) is None or \1\.owner_id != (\w+\.\w+):')
    
    def repl(m):
        return f'if {m.group(1)} is None or {m.group(1)}.owner_id != {m.group(2)} or getattr({m.group(1)}, "deleted_at", None) is not None:'
        
    new_content, count = pattern.subn(repl, content)
    if count > 0:
        content = new_content
        changed = True

    # Also handle `if album and (album.owner_id != current_user.id):`
    pattern2 = re.compile(r'if (\w+) and \(\1\.owner_id != (\w+\.\w+)\):')
    def repl2(m):
        return f'if {m.group(1)} and ({m.group(1)}.owner_id != {m.group(2)} or getattr({m.group(1)}, "deleted_at", None) is not None):'
    new_content, count = pattern2.subn(repl2, content)
    if count > 0:
        content = new_content
        changed = True

    if changed:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"Fixed {filepath}")

for f in files:
    fix_file(f)
