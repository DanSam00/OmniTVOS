#!/usr/bin/env python3
"""One-off: add the public "Omni" iOS and tvOS targets to NuvioTV.xcodeproj.

Each is a clone of the Omni X app target ("Omni iOS" / "NuvioTV") built
WITHOUT the OMNI_X compilation condition, under its own bundle id, and for
now without the widget / Top Shelf extensions (and so without an App Group),
like the public Mac target made by add_omni_store_target.py.

Run from the repo root:  python3 scripts/add_omni_store_mobile_targets.py
"""
import hashlib, re, sys

PBX = "tvosApp/NuvioTV.xcodeproj/project.pbxproj"
text = open(PBX).read()
if "OSIOTARGET" in text:
    sys.exit("already applied")


def block(obj_id):
    m = re.search(r"\t\t%s /\* [^\n]*? \*/ = \{\n.*?\n\t\t\};\n" % re.escape(obj_id), text, re.S)
    if not m:
        sys.exit("no block for " + obj_id)
    return m.group(0)


def build_file_line(bid):
    m = re.search(r"\t\t%s /\* .*? \*/ = \{isa = PBXBuildFile;.*?\};\n" % re.escape(bid), text)
    if not m:
        sys.exit("no build file " + bid)
    return m.group(0)


def insert_after(anchor, payload):
    global text
    i = text.index(anchor) + len(anchor)
    text = text[:i] + payload + text[i:]


def insert_before(marker, payload):
    global text
    i = text.index(marker)
    text = text[:i] + payload + text[i:]


def clone_target(src, tag, name, product, bundle_id, plist, drop_phases):
    """Clones target `src`; new object ids start with `tag` (4 chars)."""
    global text
    nid = lambda old: tag + hashlib.md5(old.encode()).hexdigest()[:20].upper()
    tgt = block(src)
    phases = re.search(r"buildPhases = \(\n(.*?)\n\t\t\t\);", tgt, re.S).group(1)
    ntgt = tgt.replace(src, tag + "TARGET00000000000004")
    for pid, label in re.findall(r"\t\t\t\t(\S+) /\* (.*?) \*/,", phases):
        if pid in drop_phases:
            ntgt = re.sub(r"\t\t\t\t%s /\*.*?\*/,\n" % re.escape(pid), "", ntgt)
            continue
        pb = block(pid)
        npb = pb.replace(pid, nid(pid))
        files = re.search(r"files = \(\n(.*?)\t\t\t\);", pb, re.S)
        new_bfs = ""
        if files:
            for bid in re.findall(r"\t\t\t\t(\S+) /\*", files.group(1)):
                npb = npb.replace(bid, nid(bid))
                new_bfs += build_file_line(bid).replace(bid, nid(bid))
        insert_after(pb, npb)               # keeps it in the same section
        if new_bfs:
            insert_before("/* End PBXBuildFile section */", new_bfs)
        ntgt = ntgt.replace(pid, nid(pid))
    # No extension dependencies.
    ntgt = re.sub(r"dependencies = \(\n.*?\n\t\t\t\);", "dependencies = (\n\t\t\t);", ntgt, flags=re.S)
    old_product = re.search(r"productReference = (\S+) /\* (.*?) \*/;", ntgt)
    pref = tag + "TARGET00000000000005"
    ntgt = ntgt.replace(old_product.group(0), "productReference = %s /* %s.app */;" % (pref, product))
    old_list = re.search(r"buildConfigurationList = (\S+) ", ntgt).group(1)
    nlist_id = tag + "TARGET00000000000006"
    ntgt = ntgt.replace(old_list, nlist_id)
    ntgt = re.sub(r'/\* Build configuration list for PBXNativeTarget ".*?" \*/',
                  '/* Build configuration list for PBXNativeTarget "%s" */' % name, ntgt)
    ntgt = re.sub(r"\t\t(\S+) /\* .*? \*/ = \{", r'\t\t\1 /* %s */ = {' % name, ntgt, count=1)
    ntgt = re.sub(r"\n\t\t\tname = .*?;", '\n\t\t\tname = "%s";' % name, ntgt, count=1)
    ntgt = re.sub(r"\n\t\t\tproductName = .*?;", '\n\t\t\tproductName = "%s";' % product, ntgt, count=1)

    lst = block(old_list)
    nlst = lst.replace(old_list, nlist_id)
    nlst = re.sub(r'PBXNativeTarget ".*?"', 'PBXNativeTarget "%s"' % name, nlst)
    cfgs = ""
    for n, cid in enumerate(re.findall(r"\t\t\t\t(\S+) /\* (?:Debug|Release) \*/", lst)):
        ncid = tag + "TARGET0000000000000%d" % (7 + n)
        nlst = nlst.replace(cid, ncid)
        b = block(cid).replace(cid, ncid)
        b = re.sub(r'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "\$\(inherited\) OMNI_X";\n\t*', "", b)
        b = b.replace("$(inherited) OMNI_X OMNI_DEBUG_TOOLS", "$(inherited) OMNI_DEBUG_TOOLS")
        b = re.sub(r"\t*CODE_SIGN_ENTITLEMENTS = .*?;\n", "", b)
        b = re.sub(r"INFOPLIST_FILE = .*?;", 'INFOPLIST_FILE = "%s";' % plist, b)
        b = re.sub(r"PRODUCT_BUNDLE_IDENTIFIER = .*?;", "PRODUCT_BUNDLE_IDENTIFIER = %s;" % bundle_id, b)
        b = re.sub(r"PRODUCT_NAME = .*?;", 'PRODUCT_NAME = "%s";' % product, b)
        assert "OMNI_X" not in b, b
        cfgs += b

    insert_before("/* End PBXFileReference section */",
                  '\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
                  'includeInIndex = 0; path = "%s.app"; sourceTree = BUILT_PRODUCTS_DIR; };\n' % (pref, product, product))
    insert_before("/* End PBXNativeTarget section */", ntgt)
    insert_before("/* End XCBuildConfiguration section */", cfgs)
    insert_before("/* End XCConfigurationList section */", nlst)
    # Products group and the project's target list.
    text = text.replace("\t\t\t\tOSTRTARGET000000000000005 /* Omni.app */,\n",
                        "\t\t\t\tOSTRTARGET000000000000005 /* Omni.app */,\n\t\t\t\t%s /* %s.app */,\n" % (pref, product), 1)
    text = text.replace("\t\t\t\tOSTRTARGET000000000000004 /* Omni */,\n",
                        "\t\t\t\tOSTRTARGET000000000000004 /* Omni */,\n\t\t\t\t%sTARGET00000000000004 /* %s */,\n" % (tag, name), 1)


clone_target("IOSID000000000000000007F", "OSIO", "Omni Store iOS", "Omni Store",
             "com.saminaden.omnistore.ios", "NuvioTV/Info-Store-iOS.plist",
             drop_phases={"OWGT00000000000000000C03"})
clone_target("13B07F861A680F5B00A75B9A", "OSTV", "Omni Store tvOS", "Omni Store",
             "com.saminaden.omnistore.tv", "NuvioTV/Info-Store-tvOS.plist",
             drop_phases={"7E51000000000000000000C3"})
open(PBX, "w").write(text)
print("ok")
