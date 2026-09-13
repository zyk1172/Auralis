import subprocess

text = subprocess.check_output(
    ['git', 'show', '9f9fe0bab19ad06ea3ab5325f4c59fe6cd751ae2:.github/workflows/semantic-collision-bootstrap.yml'],
    text=True,
)
start = "          python3 - <<'PY'\n"
end = "\n          PY\n"
if start not in text or end not in text:
    raise SystemExit('bootstrap payload markers not found in historical workflow')
payload = text.split(start, 1)[1].rsplit(end, 1)[0]
# Executable heredoc lines had ten YAML indentation spaces; raw triple-quoted
# file bodies intentionally had none. Strip only that fixed prefix.
lines = [line[10:] if line.startswith('          ') else line for line in payload.splitlines()]
code = '\n'.join(lines) + '\n'
exec(compile(code, '<semantic-collision-bootstrap>', 'exec'))
