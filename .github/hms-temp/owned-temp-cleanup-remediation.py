from pathlib import Path
import subprocess

BASELINES = {
    "scripts/Build-HmsCompositeSkill.ps1": "c3a43862cadb0f8a5ae754c1efd8f91479f74594",
    "scripts/Copy-HmsCommittedGitPath.ps1": "27f94d8f13f65391974126ae56d6573fd63cb6d6",
}

OLD = "        int size = nameOffset + nameBytes.Length;"
NEW = "        int minimumStructSize = IntPtr.Size == 8 ? 24 : 16;\n        int size = Math.Max(minimumStructSize, nameOffset + nameBytes.Length + 2); // trailing UTF-16 NUL/padding; FileNameLength still excludes it."


def blob(path):
    return subprocess.check_output(["git", "rev-parse", f"HEAD:{path}"], text=True).strip().lower()


for path, expected in BASELINES.items():
    actual = blob(path)
    if actual != expected:
        raise SystemExit(f"baseline drift {path}: expected {expected}, found {actual}")

for path in BASELINES:
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    count = text.count(OLD)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one old FILE_RENAME_INFO allocation, found {count}")
    updated = text.replace(OLD, NEW, 1)
    if updated.count("Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);") != 1:
        raise SystemExit(f"{path}: FileNameLength authority changed unexpectedly")
    if "nameOffset + nameBytes.Length + 2" not in updated or "minimumStructSize" not in updated:
        raise SystemExit(f"{path}: safe FILE_RENAME_INFO tail allocation missing")
    p.write_text(updated, encoding="utf-8", newline="\n")

subprocess.check_call(["git", "diff", "--check"])
changed = subprocess.check_output(["git", "diff", "--name-only"], text=True).splitlines()
if sorted(changed) != sorted(BASELINES):
    raise SystemExit("unexpected patch scope: " + ", ".join(changed))
print("PATCH_OK=YES")
