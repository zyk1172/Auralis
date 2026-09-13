from pathlib import Path

workflow = Path('.github/workflows/semantic-collision-bootstrap.yml')
text = workflow.read_text()
start = "          python3 - <<'PY'\n"
end = "\n          PY\n"
if start not in text or end not in text:
    raise SystemExit('bootstrap payload markers not found')
payload = text.split(start, 1)[1].rsplit(end, 1)[0]
# The original workflow stored the Python heredoc with ten YAML indentation
# spaces on executable lines. Raw triple-quoted file bodies intentionally had
# no YAML indentation. Strip only that fixed prefix; leave raw bodies intact.
lines = [line[10:] if line.startswith('          ') else line for line in payload.splitlines()]
code = '\n'.join(lines) + '\n'
exec(compile(code, '<semantic-collision-bootstrap>', 'exec'))
