#!/usr/bin/env python3
"""Add Swift files to every Sources phase that already builds CommunityCollections.swift.

usage: python3 scripts/add_swift_files.py NuvioTV/Sources/Core/Addons/AppEdition.swift ...
(paths are relative to tvosApp/, as in the project file)
"""
import hashlib, re, sys

PBX = "tvosApp/NuvioTV.xcodeproj/project.pbxproj"
ANCHOR_REF = "CMCL00000000000000000001"
text = open(PBX).read()


def nid(seed):
    return "OSF" + hashlib.md5(seed.encode()).hexdigest()[:21].upper()


anchor_builds = re.findall(r"\t\t(\S+) /\* .*? in Sources \*/ = \{isa = PBXBuildFile; fileRef = %s " % ANCHOR_REF, text)
phases = []
for b in anchor_builds:
    m = re.search(r"\t\t(\S+) /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;.*?\n\t\t\};\n", text, re.S)
    for m in re.finditer(r"\t\t(\S+) /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;.*?\n\t\t\};\n", text, re.S):
        if b in m.group(0):
            phases.append(m.group(1))
for path in sys.argv[1:]:
    if path in text:
        print("already:", path); continue
    ref = nid("ref" + path)
    text = text.replace("/* End PBXFileReference section */",
        f'\t\t{ref} /* {path} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
    text = text.replace(f"\t\t\t\t{ANCHOR_REF} /* NuvioTV/Sources/Core/Collections/CommunityCollections.swift */,\n",
        f"\t\t\t\t{ANCHOR_REF} /* NuvioTV/Sources/Core/Collections/CommunityCollections.swift */,\n\t\t\t\t{ref} /* {path} */,\n", 1)
    for ph in phases:
        bid = nid(ph + path)
        text = text.replace("/* End PBXBuildFile section */",
            f"\t\t{bid} /* {path} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path} */; }};\n/* End PBXBuildFile section */")
        m = re.search(r"(\t\t%s /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)" % re.escape(ph), text)
        text = text[:m.end()] + f"\t\t\t\t{bid} /* {path} in Sources */,\n" + text[m.end():]
    print("added:", path, "to", len(phases), "phases")
open(PBX, "w").write(text)
