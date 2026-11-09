#!/usr/bin/env python3
"""Adds every Swift file under ios/native/App/App (subfolders too) to the Xcode project's App
target, so a new file only has to be written. Files already in the project are left alone."""
import pathlib, re, secrets

root = pathlib.Path(__file__).resolve().parents[2]
app = root / "ios/native/App/App"
pbx = root / "ios/native/App/App.xcodeproj/project.pbxproj"
s = pbx.read_text()

# Anchors: the existing SceneDelegate.swift entries (the template always has it).
build_anchor = re.search(r"\t\t\w{24} /\* SceneDelegate\.swift in Sources \*/ = \{[^\n]*\n", s).group(0)
ref_anchor = re.search(r"\t\t\w{24} /\* SceneDelegate\.swift \*/ = \{isa = PBXFileReference;[^\n]*\n", s).group(0)
group_anchor = re.search(r"\t\t\t\t\w{24} /\* SceneDelegate\.swift \*/,\n", s).group(0)
phase_anchor = re.search(r"\t\t\t\t\w{24} /\* SceneDelegate\.swift in Sources \*/,\n", s).group(0)

def uid():
    while True:
        u = secrets.token_hex(12).upper()
        if u not in s:
            return u

added = []
for f in sorted(app.rglob("*.swift")):
    rel = f.relative_to(app).as_posix()
    if f"path = {rel};" in s or f'path = "{rel}";' in s:
        continue
    ref, build = uid(), uid()
    path = f'"{rel}"' if "/" in rel or " " in rel else rel
    s = s.replace(build_anchor, build_anchor + f"\t\t{build} /* {f.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {f.name} */; }};\n", 1)
    s = s.replace(ref_anchor, ref_anchor + f'\t\t{ref} /* {f.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = "<group>"; }};\n', 1)
    s = s.replace(group_anchor, group_anchor + f"\t\t\t\t{ref} /* {f.name} */,\n", 1)
    s = s.replace(phase_anchor, phase_anchor + f"\t\t\t\t{build} /* {f.name} in Sources */,\n", 1)
    added.append(rel)

pbx.write_text(s)
print(f"added {len(added)}: " + ", ".join(added) if added else "nothing to add")
