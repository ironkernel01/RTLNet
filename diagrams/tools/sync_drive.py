#!/usr/bin/env python3
"""Mirror built drawing sets (.pptx) and document PDFs to the project's Google Drive folder.

For each diagrams/out/<name>.pptx this keeps two reference copies in Drive:
  <folder>/<name>             Google Slides (converted; the copy people open and share)
  <folder>/pptx/<name>.pptx   the exact .pptx that was built (binary, updated in place)
For each document PDF (git-tracked, in a folder named documentation):
  <folder>/pdf/<name>.pdf     the exact PDF, updated in place: the file ID, view link and
                              download link stay the same on every sync, so a web page can
                              link to them once.

File IDs and links are recorded in diagrams/drive-index.json (commit it), so later syncs
update the same files and links in documents and on the website stay valid.

Setup (once per PC):
  pip install google-api-python-client google-auth-oauthlib
  Put an OAuth "Desktop app" client file at ~/.config/eng-slides/credentials.json
  (Google Cloud console of the IronKernel account: enable the Drive API, create an
  OAuth client ID, type Desktop app). The first run opens a browser to authorize;
  sign in with the IronKernel account. The token is cached next to credentials.json.
  Set folder_id in diagrams/drive-config.json to the Drive folder of this project.
  For the website, share <folder>/pdf once as "Anyone with the link: Viewer";
  PDFs added later inherit it.

Usage:
  python diagrams/tools/sync_drive.py <file.pptx|file.pdf> [more ...]
  python diagrams/tools/sync_drive.py --all         every drawing set and document PDF
  python diagrams/tools/sync_drive.py --pdfs        document PDFs only
  python diagrams/tools/sync_drive.py --drawings    drawing sets only
  add --dry-run to list what would be synced without contacting Drive
"""
import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]           # diagrams/
REPO = ROOT.parent
INDEX = ROOT / "drive-index.json"
CONFIG = ROOT / "drive-config.json"                   # {"folder_id": "..."}
CRED_DIR = Path.home() / ".config" / "eng-slides"
SCOPES = ["https://www.googleapis.com/auth/drive"]
PPTX = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
PDF = "application/pdf"
SLIDES = "application/vnd.google-apps.presentation"
FOLDER = "application/vnd.google-apps.folder"
FIELDS = "id,name,webViewLink,modifiedTime"


def service():
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from googleapiclient.discovery import build

    token = CRED_DIR / "token.json"
    creds = Credentials.from_authorized_user_file(token, SCOPES) if token.exists() else None
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(CRED_DIR / "credentials.json", SCOPES)
            creds = flow.run_local_server(port=0)
        token.write_text(creds.to_json())
    return build("drive", "v3", credentials=creds)


def http_error():
    from googleapiclient.errors import HttpError
    return HttpError


def media(path, mime):
    from googleapiclient.http import MediaFileUpload
    return MediaFileUpload(str(path), mimetype=mime, resumable=True)


def find(drive, name, parent, mime):
    q = (f"name = '{name.replace(chr(39), chr(92) + chr(39))}' and '{parent}' in parents "
         f"and mimeType = '{mime}' and trashed = false")
    r = drive.files().list(q=q, fields=f"files({FIELDS})", supportsAllDrives=True,
                           includeItemsFromAllDrives=True).execute()
    return r["files"][0] if r["files"] else None


def exists(drive, file_id):
    try:
        f = drive.files().get(fileId=file_id, fields="id,trashed", supportsAllDrives=True).execute()
        return not f.get("trashed")
    except http_error():
        return False


def subfolder(drive, parent, name):
    f = find(drive, name, parent, FOLDER)
    if f:
        return f["id"]
    body = {"name": name, "mimeType": FOLDER, "parents": [parent]}
    return drive.files().create(body=body, fields="id", supportsAllDrives=True).execute()["id"]


def put_binary(drive, path, mime, folder, known_id):
    """Upload path into folder, updating known_id (or a same-named file) in place."""
    fid = known_id if known_id and exists(drive, known_id) else None
    if not fid:
        hit = find(drive, path.name, folder, mime)
        fid = hit["id"] if hit else None
    if fid:
        return drive.files().update(fileId=fid, media_body=media(path, mime), fields=FIELDS,
                                    supportsAllDrives=True).execute()
    body = {"name": path.name, "parents": [folder]}
    return drive.files().create(body=body, media_body=media(path, mime), fields=FIELDS,
                                supportsAllDrives=True).execute()


def sync_pptx(drive, pptx, folder_id, index):
    name = pptx.stem
    entry = index.get(name, {})

    # 1. Exact .pptx, updated in place.
    p = put_binary(drive, pptx, PPTX, subfolder(drive, folder_id, "pptx"), entry.get("pptx_id"))

    # 2. Google Slides copy. Try to re-import into the existing file so its link stays the same.
    sid = entry.get("slides_id")
    if not (sid and exists(drive, sid)):
        hit = find(drive, name, folder_id, SLIDES)
        sid = hit["id"] if hit else None
    s, note = None, ""
    if sid:
        try:
            s = drive.files().update(fileId=sid, media_body=media(pptx, PPTX), fields=FIELDS,
                                     supportsAllDrives=True).execute()
        except http_error() as e:
            # In-place re-import refused: keep the old copy under a dated name, create a new one.
            stamp = datetime.date.today().strftime("%m-%d-%Y")
            drive.files().update(fileId=sid, body={"name": f"{name} (superseded {stamp})"},
                                 supportsAllDrives=True).execute()
            note = f"in-place update refused ({e.resp.status}); previous copy renamed, new link issued"
    if s is None:
        body = {"name": name, "mimeType": SLIDES, "parents": [folder_id]}
        s = drive.files().create(body=body, media_body=media(pptx, PPTX), fields=FIELDS,
                                 supportsAllDrives=True).execute()

    index[name] = {
        "slides_id": s["id"], "slides_link": s["webViewLink"],
        "pptx_id": p["id"], "pptx_link": p["webViewLink"],
        "synced": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    print(f"{name}: {s['webViewLink']}" + (f"  [{note}]" if note else ""))


def sync_pdf(drive, pdf, folder_id, index):
    pdfs = index.setdefault("pdf", {})
    entry = pdfs.get(pdf.name, {})
    f = put_binary(drive, pdf, PDF, subfolder(drive, folder_id, "pdf"), entry.get("id"))
    pdfs[pdf.name] = {
        "id": f["id"], "view_link": f["webViewLink"],
        "download_link": f"https://drive.google.com/uc?export=download&id={f['id']}",
        "source": pdf.relative_to(REPO).as_posix(),
        "synced": datetime.datetime.now().isoformat(timespec="seconds"),
    }
    print(f"{pdf.name}: {f['webViewLink']}")


def document_pdfs():
    """Git-tracked PDFs in a folder named documentation (any case); reference PDFs elsewhere stay out."""
    out = subprocess.run(["git", "-C", str(REPO), "ls-files", "*.pdf"], capture_output=True,
                         text=True, check=True).stdout.split()
    return [REPO / p for p in out if any(part.lower() == "documentation" for part in Path(p).parts[:-1])]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--all", action="store_true", help="every diagrams/out/*.pptx and every document PDF")
    ap.add_argument("--pdfs", action="store_true", help="every document PDF")
    ap.add_argument("--drawings", action="store_true", help="every diagrams/out/*.pptx")
    ap.add_argument("--dry-run", action="store_true", help="list the files; do not contact Drive")
    a = ap.parse_args()

    files = [f.resolve() for f in a.files]
    if a.all or a.drawings:
        files += sorted((ROOT / "out").glob("*.pptx"))
    if a.all or a.pdfs:
        files += document_pdfs()
    if not files:
        ap.error("no files given (name .pptx/.pdf files, or use --all, --pdfs, --drawings)")
    for f in files:
        if f.suffix.lower() not in (".pptx", ".pdf"):
            ap.error(f"{f}: only .pptx and .pdf are synced")
        if not f.exists():
            ap.error(f"{f}: not found")
    if a.dry_run:
        for f in files:
            print(f.relative_to(REPO).as_posix())
        return 0

    folder_id = json.loads(CONFIG.read_text())["folder_id"]
    if not folder_id or folder_id == "TBD":
        sys.exit(f"set folder_id in {CONFIG} to the project's Google Drive folder first")
    index = json.loads(INDEX.read_text()) if INDEX.exists() else {}
    drive = service()
    try:
        for f in files:
            (sync_pdf if f.suffix.lower() == ".pdf" else sync_pptx)(drive, f, folder_id, index)
    finally:
        INDEX.write_text(json.dumps(index, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
