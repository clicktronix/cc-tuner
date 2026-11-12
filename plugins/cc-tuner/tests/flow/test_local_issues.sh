#!/usr/bin/env bash
# Execute the shared local-issue location recipe, then merge and remove the task worktree.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, re, subprocess, sys, tempfile
from pathlib import Path
plugin = Path(sys.argv[1])
reference = plugin / 'skills/task-flow/references/local-issues.md'
if not reference.is_file():
    print('FAIL shared-local-issue-location-missing')
    raise SystemExit(1)
recipe = re.findall(r'```bash\n(.*?)```', reference.read_text(), re.S)[0]
def run(args, cwd, env):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, check=True).stdout.strip()
with tempfile.TemporaryDirectory(prefix='cc-local-issues-') as directory:
    base = Path(directory).resolve()
    main, task = base / 'main checkout', base / 'task checkout'
    env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
    env.update(HOME=str(base), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
    run(['git','init','-q','-b','main',str(main)],base,env)
    run(['git','config','user.name','Fixture'],main,env)
    run(['git','config','user.email','fixture@example.invalid'],main,env)
    (main / '.gitignore').write_text('.scratch/\n')
    run(['git','add','.gitignore'],main,env)
    run(['git','commit','-qm','Create fixture'],main,env)
    run(['git','worktree','add','-b','task',str(task)],main,env)
    for kind in ['primary', 'groom', 'followup']:
        relative = '.scratch/' + kind + '/issues/01-task.md'
        located = Path(run(['/bin/bash','-c',recipe],task,dict(env,ISSUE_REL=relative)))
        assert located == main / relative, located
        located.parent.mkdir(parents=True)
        located.write_text('# Task\nStatus: open\n## Comments\nPreserve this history.\n')
        print('PASS ' + kind + '-ignored-issue-in-persistent-checkout')
    relative = 'docs/issues/01-task.md'
    located = Path(run(['/bin/bash','-c',recipe],task,dict(env,ISSUE_REL=relative)))
    assert located == task / relative
    located.parent.mkdir(parents=True)
    located.write_text('# Tracked task\n')
    run(['git','add',relative],task,env)
    run(['git','commit','-qm','Record tracked issue'],task,env)
    # A tracked file remains task-owned even when a new ignore rule would cover it.
    with (task / '.gitignore').open('a') as file: file.write('docs/issues/\n')
    assert Path(run(['/bin/bash','-c',recipe],task,dict(env,ISSUE_REL=relative))) == located
    run(['git','add','.gitignore'],task,env)
    run(['git','commit','-qm','Ignore untracked issues'],task,env)
    assert run(['git','status','--porcelain'],task,env) == ''
    run(['git','merge','--ff-only','task'],main,env)
    run(['git','worktree','remove',str(task)],main,env)
    assert (main / relative).read_text() == '# Tracked task\n'
    for kind in ['primary', 'groom', 'followup']:
        assert 'Preserve this history.' in (main / '.scratch' / kind / 'issues/01-task.md').read_text()
    print('PASS tracked-issue-merges-and-all-ignored-issues-survive-cleanup')
PY
