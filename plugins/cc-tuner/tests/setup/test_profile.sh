#!/usr/bin/env bash
# Execute the shipped statusline recipes against isolated default and custom profiles.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

plugin = Path(sys.argv[1])
text = (plugin / 'skills/setup/references/statusline.md').read_text()
def blocks(section):
    body = text.split('## ' + section + '\n', 1)[1].split('\n## ', 1)[0]
    return '\n'.join(re.findall(r'```bash\n(.*?)```', body, re.S))
locate = blocks('Locate the bundled script')
def run(recipe, env, payload=None):
    return subprocess.run(['/bin/bash', '-c', recipe], env=env, cwd=env['HOME'], input=payload,
                          text=True, capture_output=True)
def require(ok, label, detail=''):
    print(('PASS ' if ok else 'FAIL ') + label + ((' ' + detail) if not ok else ''))
    if not ok: raise SystemExit(1)

with tempfile.TemporaryDirectory(prefix='cc-profile-') as directory:
    root = Path(directory)
    for custom in [True, False]:
        home = root / ('custom-home' if custom else 'default-home')
        default = home / '.claude'
        profile = home / "profile ' $(touch SHOULD_NOT_EXIST)" if custom else default
        default.mkdir(parents=True)
        profile.mkdir(parents=True, exist_ok=True)
        baseline = json.dumps({'env': {'KEEP': 'yes'}, 'other': 1})
        (profile / 'settings.json').write_text(baseline)
        if custom: (default / 'settings.json').write_text('{"default": true}')
        # The old recipe defined DEST in prose; retain that input when observing its failure.
        env = dict(os.environ, HOME=str(home), PLUGIN=str(plugin), DEST=str(default / 'cc-tuner-statusline.sh'))
        env.pop('CLAUDE_CONFIG_DIR', None)
        if custom: env['CLAUDE_CONFIG_DIR'] = str(profile)
        label = 'custom' if custom else 'default'
        before = (profile / 'settings.json').read_bytes()
        result = run(locate + '\n' + blocks('check'), env)
        require(result.returncode == 0 and (profile / 'settings.json').read_bytes() == before,
                label + '-check-read-only', result.stderr)
        result = run(locate + '\n' + blocks('install'), env)
        require(result.returncode == 0, label + '-install', result.stderr)
        settings = json.loads((profile / 'settings.json').read_text())
        require('statusLine' in settings, label + '-active-settings')
        require(settings['env'] == {'KEEP': 'yes'} and settings['other'] == 1, label + '-preserve-keys')
        require((profile / 'cc-tuner-statusline.sh').is_file(), label + '-active-script')
        payload = json.dumps({'rate_limits': {'five_hour': {'used_percentage': 12},
                                            'seven_day': {'used_percentage': 34}}})
        result = run(settings['statusLine']['command'], env, payload)
        require(result.returncode == 0 and '5h:12%' in result.stdout,
                label + '-command-handles-path-metacharacters', result.stderr)
        require(not (home / 'SHOULD_NOT_EXIST').exists(), label + '-no-command-injection')
        result = run(locate + '\n' + blocks('install'), env)
        require(result.returncode == 0 and json.loads((profile / 'settings.json').read_text()) == settings,
                label + '-reinstall-preserves-settings')
        result = run(locate + '\n' + blocks('remove'), env)
        require(result.returncode == 0 and json.loads((profile / 'settings.json').read_text()) == json.loads(baseline),
                label + '-remove-own-setting', result.stderr)
        require(not (profile / 'cc-tuner-statusline.sh').exists(), label + '-remove-own-script')
        if custom:
            require((default / 'settings.json').read_text() == '{"default": true}'
                    and not (default / 'cc-tuner-statusline.sh').exists(), label + '-default-untouched')
        # A user-owned replacement must survive removal.
        other = {'statusLine': {'type': 'command', 'command': 'echo user-owned'}, 'other': 2}
        (profile / 'settings.json').write_text(json.dumps(other))
        result = run(locate + '\n' + blocks('remove'), env)
        require(result.returncode == 0 and json.loads((profile / 'settings.json').read_text()) == other,
                label + '-remove-preserves-foreign-command')
PY
