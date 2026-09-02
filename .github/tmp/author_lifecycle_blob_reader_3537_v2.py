from pathlib import Path

patcher_path = Path('.github/tmp/author_lifecycle_blob_reader_3537.py')
source = patcher_path.read_text(encoding='utf-8')

insert_anchor = "\n\nreplace_exact(root / 'install.ps1', old_bootstrap, new_bootstrap, 'install bootstrap')"
helper_call = "replace_exact(root / 'scripts' / 'Initialize-HmsLifecycleTrust.ps1', old_helper, new_helper, 'committed blob helper')"

structural_helper = r'''
def replace_helper_structural(path: Path, new: str) -> None:
    raw = path.read_bytes()
    text = raw.decode('utf-8')
    start_marker = "    $psi = New-Object Diagnostics.ProcessStartInfo\n    $psi.FileName = 'git'\n    $psi.Arguments = \"cat-file blob $expected\"\n"
    end_marker = "\n    $header = [Text.Encoding]::ASCII.GetBytes(('blob ' + [string]$bytes.Length + [char]0))"
    if text.count(start_marker) != 1:
        raise RuntimeError(f'committed blob helper: expected exactly one direct-git start marker, found {text.count(start_marker)}')
    start = text.index(start_marker)
    tail = text[start:]
    if tail.count(end_marker) != 1:
        raise RuntimeError(f'committed blob helper: expected exactly one SHA-1 boundary after direct-git block, found {tail.count(end_marker)}')
    end = text.index(end_marker, start)
    old_segment = text[start:end]
    required = [
        '$psi.RedirectStandardOutput = $true',
        '$psi.RedirectStandardError = $true',
        '$proc.StandardOutput.BaseStream.CopyTo($memory)',
        '$proc.StandardError.ReadToEnd()',
        '$proc.WaitForExit()',
        '$bytes = $memory.ToArray()',
        '$memory.Dispose()',
        '$proc.Dispose()'
    ]
    missing = [item for item in required if item not in old_segment]
    if missing:
        raise RuntimeError('committed blob helper: direct-git segment contract mismatch: ' + ', '.join(missing))
    path.write_bytes((text[:start] + new + text[end:]).encode('utf-8'))
'''

if source.count(insert_anchor) != 1:
    raise RuntimeError('wrapper could not locate exact insertion anchor in v1 patcher')
if source.count(helper_call) != 1:
    raise RuntimeError('wrapper could not locate exact helper call in v1 patcher')

source = source.replace(insert_anchor, '\n\n' + structural_helper + insert_anchor.lstrip('\n'), 1)
source = source.replace(helper_call, "replace_helper_structural(root / 'scripts' / 'Initialize-HmsLifecycleTrust.ps1', new_helper)", 1)
exec(compile(source, str(patcher_path), 'exec'), {'__name__': '__main__'})
