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

# The historical YAML was intentionally used only as a payload container. Its
# executable Python lines have ten YAML indentation spaces, while the bodies of
# Python triple-quoted strings carry their own meaningful indentation. Remove
# the YAML prefix only outside string bodies (and on delimiter lines).
lines = []
in_triple = False
for line in payload.splitlines():
    has_delimiter = "'''" in line
    if (not in_triple or has_delimiter) and line.startswith('          '):
        line = line[10:]
    lines.append(line)
    if line.count("'''") % 2 == 1:
        in_triple = not in_triple

code = '\n'.join(lines) + '\n'
exec(compile(code, '<semantic-collision-bootstrap>', 'exec'))
