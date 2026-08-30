#!/usr/bin/env python3
"""Deterministic, credential-free fulfillment for Vaultline Ingest applications."""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, sys, uuid
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

RELEASE = {
    "version": "0.3.0", "build": "17",
    "sourceCommit": "67edbe7450d10933d01e90d3132e7c1be76c26c2",
    "tag": "ingest-v0.3.0",
    "releasePage": "https://github.com/jake-vaultline/vaultline-labs/releases/tag/ingest-v0.3.0",
    "dmgURL": "https://github.com/jake-vaultline/vaultline-labs/releases/download/ingest-v0.3.0/VaultlineIngest-0.3.0.dmg",
    "sha256": "7fb29c2cfa78920e674346cf8da8b34e5a3ed2f2e8d93185650c0d9d519a25c0",
    "qualificationReceipt": "VLP-522/VLV-1239..VLV-1244",
    "releaseClaims": ["Developer ID signed", "Apple notarized", "stapled", "universal arm64+x86_64", "macOS 13+"],
}
STATES = ["accepted", "clarification", "configured", "synthetic-qa", "release-bound", "delivered", "failed"]
TOKENS = {"shootDate", "shooter", "location", "project", "camera", "jobNumber", "reel", "notes"}
FIELD_KINDS = {"text", "longText", "choice", "date", "toggle"}
NAMING_TOKENS = {"date", "seq", "reel", "code", "word", "text"}

class FulfillmentError(ValueError): pass
def canonical(value): return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
def digest(value): return hashlib.sha256(canonical(value)).hexdigest()
def clean_text(value, name):
    if not isinstance(value, str) or not value.strip(): raise FulfillmentError(f"{name} is required")
    return value.strip()
def safe_path(value, name, allow_empty=False):
    value = value.strip().replace("\\", "/")
    if allow_empty and not value: return ""
    p = PurePosixPath(value)
    if not value or value.startswith(("/", "~")) or any(x in ("", ".", "..") or ":" in x for x in p.parts):
        raise FulfillmentError(f"{name} must be a safe relative path")
    return str(p)
def tokens(template):
    found = re.findall(r"\{([A-Za-z][A-Za-z0-9]*)(?::[^}]+)?\}", template)
    if "{" in re.sub(r"\{[A-Za-z][A-Za-z0-9]*(?::[^}]+)?\}", "", template): raise FulfillmentError("invalid template")
    return found

def stable_uuid(*parts):
    """Return a deterministic RFC 4122 UUID without applicant-specific state."""
    raw = bytearray(hashlib.sha256("\x1f".join(parts).encode()).digest()[:16])
    raw[6] = (raw[6] & 0x0F) | 0x50
    raw[8] = (raw[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(raw))).upper()

def build_profile(resolved):
    """Only structured operator resolutions become rules; raw intake remains provenance."""
    team = clean_text(resolved.get("teamName"), "teamName")
    fields = resolved.get("fields")
    workflows = resolved.get("workflows")
    if not isinstance(fields, list) or not fields: raise FulfillmentError("resolved fields are required")
    if not isinstance(workflows, list) or not workflows: raise FulfillmentError("resolved workflows are required")
    normalized_fields=[]; available={"date"}
    for i, f in enumerate(fields):
        token=clean_text(f.get("token"), f"fields[{i}].token")
        if token not in TOKENS: raise FulfillmentError(f"unsupported field token: {token}")
        if token in available: raise FulfillmentError(f"duplicate field token: {token}")
        available.add(token)
        kind=f.get("kind", "text")
        if kind not in FIELD_KINDS: raise FulfillmentError(f"unsupported field kind: {kind}")
        options=f.get("options", [])
        if not isinstance(options, list) or any(not isinstance(x, str) or not x.strip() for x in options):
            raise FulfillmentError(f"fields[{i}].options must contain non-empty strings")
        automatic=f.get("automaticValue")
        if automatic not in (None, "today"): raise FulfillmentError(f"unsupported automatic value: {automatic}")
        normalized_fields.append({"id": stable_uuid("vaultline-ingest-field-v1", str(i), token), "kind": kind,
          "label": clean_text(f.get("label"), f"fields[{i}].label"), "required": bool(f.get("required", False)),
          "sticky": bool(f.get("sticky", False)), "options": options,
          "defaultValue": f.get("defaultValue", ""), "token": token, "automaticValue": automatic})
    normalized_workflows=[]
    for i,w in enumerate(workflows):
        folders=[safe_path(x, f"workflows[{i}].folders") for x in w.get("folders", [])]
        if not folders or len(folders)!=len(set(folders)): raise FulfillmentError("folder list must be non-empty and unique")
        media=safe_path(clean_text(w.get("mediaFolder"), "mediaFolder"), "mediaFolder")
        if media not in folders: raise FulfillmentError("mediaFolder must be present in folders")
        job=clean_text(w.get("jobNameTemplate"), "jobNameTemplate")
        unknown=set(tokens(job))-available
        if unknown: raise FulfillmentError("unresolved template tokens: "+", ".join(sorted(unknown)))
        project_folder=w.get("projectFolder")
        if project_folder:
            project_folder=safe_path(project_folder,"projectFolder")
            if project_folder not in folders: raise FulfillmentError("projectFolder must be present in folders")
        project_name=w.get("projectNameTemplate")
        if project_name:
            if not project_name.lower().endswith(".prproj"): raise FulfillmentError("projectNameTemplate must end in .prproj")
            unknown=set(tokens(project_name))-available
            if unknown: raise FulfillmentError("unresolved project template tokens: "+", ".join(sorted(unknown)))
        normalized_workflows.append({"id": clean_text(w.get("id"), "workflow.id"), "name": clean_text(w.get("name"), "workflow.name"),
          "detail": clean_text(w.get("detail"), "workflow.detail"), "parentSubpath": safe_path(w.get("parentSubpath", ""),"parentSubpath",True),
          "jobNameTemplate":job,"folders":folders,"mediaFolder":media,"projectTemplateBase64":None,
          "projectFolder":project_folder,"projectNameTemplate":project_name})
    naming=resolved.get("naming", {})
    file_template=naming.get("fileTemplate", "").strip()
    folder_template=naming.get("folderTemplate", "").strip()
    unknown_naming=(set(tokens(file_template)) | set(tokens(folder_template))) - NAMING_TOKENS
    if unknown_naming: raise FulfillmentError("unsupported naming tokens: "+", ".join(sorted(unknown_naming)))
    separator=naming.get("separator", "_")
    if separator not in ("_", "-", ".", " "): raise FulfillmentError("unsupported naming separator")
    return {"schemaVersion":1,"checksum":"xxhash64","workflow":{"manifest":True},
      "form":{"enabled":True,"fields":normalized_fields,"sidecarName":"INGEST-NOTES.txt","writeSidecar":True},
      "naming":{"fileTemplate":file_template,"folderTemplate":folder_template,"projectCode":"",
                "renameOnIngest":bool(naming.get("renameOnIngest", False)),"separator":separator},
      "team":{"schemaVersion":1,"teamName":team,"workflows":normalized_workflows}}

def synthetic_qa(profile):
    values={"date":"260828","shootDate":"260828","shooter":"Synthetic Operator","location":"Test Stage","project":"Synthetic Project","camera":"CAM-A","jobNumber":"JOB-001","reel":"A001","notes":"Synthetic only"}
    checks=[]
    for f in profile["form"]["fields"]:
        try: uuid.UUID(f["id"])
        except (ValueError, AttributeError): raise FulfillmentError("field id is not an RFC 4122 UUID")
    for w in profile["team"]["workflows"]:
        rendered=w["jobNameTemplate"]
        for token in tokens(rendered): rendered=re.sub(r"\{"+re.escape(token)+r"(?::[^}]+)?\}",values[token],rendered)
        if any(c in rendered for c in "/\\:*?\"<>|"): raise FulfillmentError("synthetic job name is unsafe")
        checks.append({"workflow":w["id"],"jobName":rendered,"mediaPath":"/Synthetic/"+safe_path(w["parentSubpath"],"parentSubpath",True).strip("/")+"/"+rendered+"/"+w["mediaFolder"],"result":"pass"})
    return checks

def fulfill(source, out):
    request=json.loads(Path(source).read_text())
    job_id=clean_text(request.get("jobId"),"jobId")
    if request.get("openQuestions"): return {"jobId":job_id,"state":"clarification","questions":request["openQuestions"]}
    profile=build_profile(request.get("resolved",{})); qa=synthetic_qa(profile)
    out=Path(out); out.mkdir(parents=True,exist_ok=True)
    profile_path=out/"Vaultline-Ingest-Team-Profile.json"; profile_path.write_bytes(canonical(profile)+b"\n")
    install=(f'''#!/bin/bash\nset -euo pipefail\nURL="{RELEASE['dmgURL']}"\nEXPECTED="{RELEASE['sha256']}"\nTMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT\ncurl -fL "$URL" -o "$TMP/Ingest.dmg"\nGOT=$(shasum -a 256 "$TMP/Ingest.dmg" | awk '{{print $1}}')\n[[ "$GOT" == "$EXPECTED" ]] || {{ echo "Checksum mismatch" >&2; exit 1; }}\nopen "$TMP/Ingest.dmg"\necho "Drag VaultlineIngest to Applications, then import Vaultline-Ingest-Team-Profile.json in Settings → Team Setup."\n''')
    (out/"install.command").write_text(install); (out/"install.command").chmod(0o755)
    copies=max(1, min(8, int(request.get("resolved", {}).get("copyLocations", 2))))
    guide=f"""# {profile['team']['teamName']} — Vaultline Ingest rollout\n\n1. Give each teammate this private folder. No app account is required.\n2. Run `install.command`, or download the DMG from the release page and verify SHA-256 `{RELEASE['sha256']}`.\n3. Drag VaultlineIngest to Applications. Open it, then use **Settings → Team Setup → Import** and choose `Vaultline-Ingest-Team-Profile.json`.\n4. On each Mac, add the locally mounted destinations; macOS requires that operator to grant folder access. This workflow expects {copies} destination location(s).\n5. Preview the naming, complete folder tree, media landing, and every destination before the first real ingest.\n6. Success means every destination was read back and verified; keep the MHL and readable ingest record with the job.\n\nThe app is offline, copy-only, and does not create user accounts. Contact Vaultline before changing the shared profile so every workstation remains consistent.\n"""
    (out/"GETTING-STARTED.md").write_text(guide)
    manifest={"schemaVersion":1,"jobId":job_id,"state":"release-bound","generatedAt":datetime.now(timezone.utc).isoformat(),"release":RELEASE,"syntheticQA":qa,"files":{}}
    for name in [profile_path.name,"install.command","GETTING-STARTED.md"]: manifest["files"][name]=hashlib.sha256((out/name).read_bytes()).hexdigest()
    manifest["manifestDigest"]=digest(manifest); (out/"delivery-manifest.json").write_bytes(canonical(manifest)+b"\n")
    return {"jobId":job_id,"state":"release-bound","manifest":str(out/"delivery-manifest.json"),"manifestDigest":manifest["manifestDigest"]}

def verify(directory):
    d=Path(directory); m=json.loads((d/"delivery-manifest.json").read_text()); expected=m.pop("manifestDigest")
    if digest(m)!=expected: raise FulfillmentError("manifest digest mismatch")
    for name,expected_hash in m["files"].items():
        if hashlib.sha256((d/name).read_bytes()).hexdigest()!=expected_hash: raise FulfillmentError(f"tamper detected: {name}")
    return {"state":"verified","manifestDigest":expected}

def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="command",required=True)
    f=sub.add_parser("fulfill"); f.add_argument("request"); f.add_argument("output")
    v=sub.add_parser("verify"); v.add_argument("directory")
    args=p.parse_args()
    try: result=fulfill(args.request,args.output) if args.command=="fulfill" else verify(args.directory)
    except (FulfillmentError,KeyError,json.JSONDecodeError) as e: print(json.dumps({"state":"failed","error":str(e)})); return 2
    print(json.dumps(result,sort_keys=True)); return 0
if __name__=="__main__": raise SystemExit(main())
