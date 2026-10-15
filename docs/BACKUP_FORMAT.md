# Backup format

An AgentKeyBox backup is an ordinary **AES-256 encrypted macOS disk image** (`.dmg`). You do not need AgentKeyBox to open it, so your keys are never locked in.

## Opening a backup without AgentKeyBox

1. Double-click the `.dmg` file.
2. Enter the backup password. macOS opens a disk named **AgentKeyBox Backup**.
3. Each project has a folder holding its `.env` and key files. `README.txt` lists every key and where it is.

Files whose names start with a dot, such as `.env`, are hidden in Finder. Press **Command-Shift-.** to show them.

From Terminal:

```bash
hdiutil attach "AgentKeyBox Backup 2026-10-15.dmg"
```

Copies you take out of the disk image are not encrypted. Delete them when you no longer need them, and eject the disk when you are done.

## How the image is made

`BackupArchive.write` in `Sources/AgentKeyBoxCore/BackupArchive.swift`:

1. `hdiutil create -fs APFS -encryption AES-256 -stdinpass -volname "AgentKeyBox Backup" -type UDIF` creates an empty encrypted read-write image of at least 4 MB. The password goes to `hdiutil` on standard input, never as a command-line argument.
2. `hdiutil attach -stdinpass -nobrowse -noautoopen` mounts it under a new owner-only (700) temporary folder, hidden from Finder.
3. The files below are written into the mounted volume: folders 700, files 600. Keys are never written outside the encrypted image.
4. The image is detached and attached again as a device only (`hdiutil attach -nomount`), and `hdiutil create -srcdevice <device> -format UDZO -encryption AES-256 -stdinpass` makes the finished backup from it: compressed, read-only, and encrypted with the same password. Finder opens a read-only image's window by itself after you enter the password; a read-write image would mount without opening anything. The working image is deleted.
5. The finished image is moved to the location you chose (permissions 600). An existing file there is replaced only after the new image is complete.

Import (`BackupArchive.read`) refuses images that are not encrypted. It mounts the image read-only in the same private way, reads `.agentkeybox-backup.json`, and detaches it.

The password must be at least 12 characters. macOS derives the disk key from it, so the backup is only as strong as the password.

## What the disk holds

```text
AgentKeyBox Backup/
├── README.txt                    what was backed up, and where each key is
├── my-app/
│   └── .env                      STRIPE_SECRET_KEY=…  (plus non-secret settings)
├── ios-app/
│   ├── .env                      ASC_KEY_ID=…, ASC_ISSUER_ID=…
│   └── AuthKey_ABC123DEF4.p8     the original key file
├── No project/                   keys not assigned to a project
├── .agentkeybox-backup.json      hidden; what Import… reads
└── .metadata_never_index         keeps Spotlight from indexing the open disk
```

### Project folders

- There is one folder per project that has keys, named after the project. `/`, `\`, `:`, control characters and leading dots are replaced or removed. Names that differ only by case get ` 2`, ` 3`, ….
- **`.env`** holds each text key under its environment variable name (`environmentVariableName`, or the label when that is a valid variable name), followed by the key's non-secret settings such as `ASC_ISSUER_ID`. Values made only of `A–Z a–z 0–9 _ - . / : @ + , =` are written as they are. Any other value is double-quoted, with `\\`, `\"`, `\n`, `\r` and `\t` escaped.
- **Key files** (`p8`, `pem`, `json` keys) are written as their original bytes. An App Store Connect key gets Apple's name `AuthKey_<KEY ID>.p8`; other files are named after the key's label with the right extension. A text-style key whose value is not UTF-8, or that has no valid variable name, is written as `<label>.txt`.

### `.agentkeybox-backup.json`

This is what **Import…** reads. It is UTF-8 JSON with sorted keys:

```json
{
  "format": "agentkeybox-backup",
  "version": 1,
  "contents": {
    "createdAt": 782692800.25,
    "appVersion": "0.4.0",
    "projects": [{ "id": "UUID", "name": "my-app", "rootPath": "/Users/me/my-app" }],
    "credentials": [{
      "id": "UUID", "label": "STRIPE_SECRET_KEY", "service": "Stripe",
      "projectID": "UUID", "kind": "apiKey",
      "environmentVariableName": "STRIPE_SECRET_KEY",
      "allowedHosts": ["api.stripe.com"],
      "createdAt": 782692800.0, "updatedAt": 782692800.0
    }],
    "secrets": { "CREDENTIAL-UUID": "BASE64 OF THE KEY BYTES" }
  }
}
```

- `format` is always `agentkeybox-backup`. `version` is `1`; Import refuses other versions.
- `contents` is `BackupContents`, encoded with Swift's default `JSONEncoder`:
  - Dates (`createdAt`, `updatedAt`) are numbers: seconds since **2001-01-01 00:00:00 UTC**, Apple's reference date, not the Unix epoch.
  - UUIDs are uppercase strings.
  - `secrets` maps a credential's `id` to its key bytes, Base64-encoded (standard alphabet, with padding).
  - A credential's optional fields (`projectID`, `environment`, `environmentVariableName`, `allowedHosts`, `settings`) are left out when empty.
  - `kind` is one of `apiKey`, `token`, `p8`, `pem`, `json`, `environmentVariable`.

The project folders are a readable copy of the same data. Import ignores them, so changing a `.env` inside the disk does not change what Import restores.

`Tests/AgentKeyBoxCoreTests/BackupArchiveTests.swift` checks this layout, `.env` lines read back unchanged, and a real encrypted image that opens only with its password.
