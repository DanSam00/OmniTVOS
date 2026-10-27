#!/usr/bin/env python3
"""One-off: add the public "Omni" macOS target to NuvioTV.xcodeproj.

The existing macOS target becomes "Omni X" (the full app). "Omni" is a clone
of it that is built WITHOUT the OMNI_X compilation condition, with the Mac App
Store sandbox entitlements, and without the widget extension for now.

Run from the repo root:  python3 scripts/add_omni_store_target.py
"""
import hashlib, re, sys

PBX = "tvosApp/NuvioTV.xcodeproj/project.pbxproj"
text = open(PBX).read()
if "OSTRTARGET" in text:
    sys.exit("already applied")


def nid(old):
    return "OSTR" + hashlib.md5(old.encode()).hexdigest()[:20].upper()


def section(phase_id):
    m = re.search(r"\t\t%s /\* \w+ \*/ = \{\n.*?\n\t\t\};\n" % phase_id, text, re.S)
    return m.group(0)


def files_of(block):
    return re.findall(r"\t\t\t\t(\S+) /\* (.*?) \*/,", block)


def build_file_line(bid):
    m = re.search(r"\t\t%s /\* .*? \*/ = \{isa = PBXBuildFile;.*?\};\n" % re.escape(bid), text)
    return m.group(0)


new_build_files, new_phases = [], []
for phase, label in (("MACID0000000000000000001", "Sources"),
                     ("MACID0000000000000000002", "Frameworks"),
                     ("MACID0000000000000000003", "Resources")):
    block = section(phase)
    nb = block.replace(phase, nid(phase))
    for bid, _ in files_of(block):
        if bid == "MACHELP000000000000000002":  # help book is Omni X only
            nb = re.sub(r"\t\t\t\t%s /\*.*?\*/,\n" % bid, "", nb)
            continue
        nb = nb.replace(bid, nid(bid))
        new_build_files.append(build_file_line(bid).replace(bid, nid(bid)))
    new_phases.append(nb)

# Existing Mac target -> Omni X
text = text.replace('MACID0000000000000000005 /* Omni.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Omni.app;',
                    'MACID0000000000000000005 /* Omni X.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Omni X.app";')
text = text.replace("MACID0000000000000000005 /* Omni.app */", "MACID0000000000000000005 /* Omni X.app */")
text = text.replace("MACID0000000000000000004 /* Omni */", "MACID0000000000000000004 /* Omni X */")
text = text.replace('PBXNativeTarget "Omni" */', 'PBXNativeTarget "Omni X" */')
text = re.sub(r"(MACID0000000000000000004 /\* Omni X \*/ = \{.*?)name = Omni;(.*?)productName = Omni;",
              r'\1name = "Omni X";\2productName = "Omni X";', text, count=1, flags=re.S)
# Omni X builds define OMNI_X; names it "Omni X".
for cfg in ("MACID0000000000000000007", "MACID0000000000000000008"):
    m = re.search(r"\t\t%s /\* \w+ \*/ = \{.*?\n\t\t\};\n" % cfg, text, re.S)
    b = m.group(0)
    b2 = b.replace("PRODUCT_NAME = Omni;", 'PRODUCT_NAME = "Omni X";\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) OMNI_X";')
    text = text.replace(b, b2)
text = text.replace('CFBundleDisplayName', 'CFBundleDisplayName')  # (plist edited separately)

# Clone target + configs
tgt = re.search(r"\t\tMACID0000000000000000004 /\* Omni X \*/ = \{.*?\n\t\t\};\n", text, re.S).group(0)
ntgt = tgt.replace("MACID0000000000000000004", "OSTRTARGET000000000000004")
ntgt = ntgt.replace("/* Omni X */", "/* Omni */").replace('name = "Omni X";', "name = Omni;").replace('productName = "Omni X";', "productName = Omni;")
ntgt = ntgt.replace("MACID0000000000000000006", "OSTRTARGET000000000000006")
ntgt = ntgt.replace("MACID0000000000000000005", "OSTRTARGET000000000000005").replace("Omni X.app", "Omni.app")
for p in ("1", "2", "3"):
    ntgt = ntgt.replace("MACID000000000000000000" + p, nid("MACID000000000000000000" + p))
ntgt = re.sub(r"\t\t\t\tMWGT00000000000000000C03 /\*.*?\*/,\n", "", ntgt)          # no widget embed
ntgt = re.sub(r"\t\t\t\tMWGT00000000000000000D00 /\*.*?\*/,\n", "", ntgt)          # no widget dependency

cfgs = ""
for old, new in (("MACID0000000000000000007", "OSTRTARGET000000000000007"),
                 ("MACID0000000000000000008", "OSTRTARGET000000000000008")):
    b = re.search(r"\t\t%s /\* \w+ \*/ = \{.*?\n\t\t\};\n" % old, text, re.S).group(0).replace(old, new)
    b = b.replace('PRODUCT_NAME = "Omni X";\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) OMNI_X";', "PRODUCT_NAME = Omni;")
    b = b.replace("NuvioTV/Omni-macOS.entitlements", "NuvioTV/Omni-Store-macOS.entitlements")
    b = b.replace('"NuvioTV/Info-macOS.plist"', '"NuvioTV/Info-Store-macOS.plist"')
    b = b.replace("PRODUCT_BUNDLE_IDENTIFIER = com.saminaden.omni.mac;", "PRODUCT_BUNDLE_IDENTIFIER = com.saminaden.omnistore.mac;")
    b = b.replace("ENABLE_HARDENED_RUNTIME = NO;", "ENABLE_HARDENED_RUNTIME = YES;")
    cfgs += b
lst = re.search(r"\t\tMACID0000000000000000006 /\* Build configuration list.*?\n\t\t\};\n", text, re.S).group(0)
nlst = (lst.replace("MACID0000000000000000006", "OSTRTARGET000000000000006")
        .replace("MACID0000000000000000007", "OSTRTARGET000000000000007")
        .replace("MACID0000000000000000008", "OSTRTARGET000000000000008")
        .replace('"Omni X"', '"Omni"'))
product = ('\t\tOSTRTARGET000000000000005 /* Omni.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
           'includeInIndex = 0; path = Omni.app; sourceTree = BUILT_PRODUCTS_DIR; };\n')

def insert_before(marker, payload):
    global text
    i = text.index(marker)
    text = text[:i] + payload + text[i:]

insert_before("/* End PBXBuildFile section */", "".join(new_build_files))
insert_before("/* End PBXFileReference section */", product)
insert_before("/* End PBXFrameworksBuildPhase section */", new_phases[1])
insert_before("/* End PBXResourcesBuildPhase section */", new_phases[2])
insert_before("/* End PBXSourcesBuildPhase section */", new_phases[0])
insert_before("/* End PBXNativeTarget section */", ntgt)
insert_before("/* End XCBuildConfiguration section */", cfgs)
insert_before("/* End XCConfigurationList section */", nlst)
text = text.replace("\t\t\t\tMACID0000000000000000005 /* Omni X.app */,\n",
                    "\t\t\t\tMACID0000000000000000005 /* Omni X.app */,\n\t\t\t\tOSTRTARGET000000000000005 /* Omni.app */,\n", 1)
text = text.replace("\t\t\t\tMACID0000000000000000004 /* Omni X */,\n",
                    "\t\t\t\tMACID0000000000000000004 /* Omni X */,\n\t\t\t\tOSTRTARGET000000000000004 /* Omni */,\n", 1)
open(PBX, "w").write(text)
print("ok:", len(new_build_files), "build files cloned")
