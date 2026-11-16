# PhotoHub — iPhone Photo Auto-Backup & Auto-Delete Backend

A Node.js backend built for **Apple Shortcuts** that backs up photos/videos from your iPhone to your Ubuntu VPS (`/home/ubuntu/gdrive/photoHUB/YYYY/YYYY-MM-DD/<originalName>`), verifies file integrity on disk using **SHA-256**, checks for duplicates, and supports API key authentication.

---

## Part 1: Deploy on Ubuntu VPS with Docker (Port 3000)

### 1. Prepare Folders & Start the Container
On your **Ubuntu VPS**, run:

```bash
# 1. Create the storage folder and local data folder as your 'ubuntu' user
mkdir -p /home/ubuntu/gdrive/photoHUB ./data

# 2. Copy the environment config (if .env doesn't exist yet)
cp -n .env.example .env

# 3. Rebuild and start the container on Port 3000
docker compose down
docker compose up -d --build
```

Check the container status and logs:
```bash
docker ps
docker compose logs -f
```
You will see:
```text
photohub  | PhotoHub backend listening on http://0.0.0.0:3000
photohub  | Saving verified photos to: /storage
```
*(Inside the container `/storage` is bind-mounted directly to `/home/ubuntu/gdrive/photoHUB` on your Ubuntu VPS, and `/api/health` is public so the Docker healthcheck shows `(healthy)`.)*

### 2. How to Set Up Multi-User API Keys (Different Folder per User)
1. Open `.env` on your VPS and set **`USER_KEYS`** using the format `apiKey1:folderName1,apiKey2:folderName2`:
   ```env
   PORT=3000
   USER_KEYS=mingchun:mingchun,alice_secret_key:alice,mom_key_123:mom
   ```
   - When a Shortcut uses `?apiKey=mingchun`, photos are saved to:
     `/home/ubuntu/gdrive/photoHUB/mingchun/YYYY/YYYY-MM-DD/`
   - When a Shortcut uses `?apiKey=alice_secret_key`, photos are saved to:
     `/home/ubuntu/gdrive/photoHUB/alice/YYYY/YYYY-MM-DD/`
   - When a Shortcut uses `?apiKey=mom_key_123`, photos are saved to:
     `/home/ubuntu/gdrive/photoHUB/mom/YYYY/YYYY-MM-DD/`
   - Each user folder also gets its own separate SHA-256 duplicate index (`data/hash-index-<folder>.json`).

2. Rebuild & restart the container so it picks up the new code and `.env` change:
   ```bash
   docker compose up -d --build
   ```
3. In each user's **Apple Shortcut** (`Get Contents of URL`), pass their own API key:
   - **Option 1 (Easiest — in the URL)**:
     Use `http://<YOUR_VPS_IP>:3000/api/upload?apiKey=mingchun` (or `?apiKey=alice_secret_key`)
   - **Option 2 (In Request Headers)**:
     In `Get Contents of URL`, tap **Headers** → **Add new header**:
     - Key: `X-API-Key`
     - Value: `mingchun`

### 3. Allow Port 3000 on Your VPS Firewall
- **Ubuntu UFW**:
  ```bash
  sudo ufw allow 3000/tcp
  ```
- **Cloud Provider Firewall (AWS / Oracle / DigitalOcean / etc.)**:
  Make sure **TCP Port `3000`** is open in your VPS Inbound Security Group / Firewall rules.

---

## Part 2: Enable Silent Photo Deletion on iPhone (iOS Settings)

1. Open the **Settings** app on your iPhone.
2. Scroll down to **Apps** → tap **Shortcuts**.
3. Tap **Advanced**.
4. Turn **ON** both:
   - **Allow Deleting Without Confirmation**
   - **Allow Deleting Large Amounts of Data**

---

## Part 3: Build the Apple Shortcut

Choose whichever workflow fits your needs:
- **Workflow 0**: **Backup-Only (No Delete Step Required)** — simplest 3-step Shortcut.
- **Workflow A**: **Upload After Deleting on Device**.
- **Workflow B**: **Backup First, Then Ask User Whether to Delete at the End**.

---

### Workflow 0: Simple Backup-Only (No Delete Function Needed)

If you just want your Shortcut to **back up photos to the server without deleting anything** (and automatically skip duplicates on future runs):

```text
1. Find Photos (All Photos, Sort by Creation Date Oldest First, Limit 50)
2. Repeat with each item in [Photos]
     └─ Get contents of [http://<VPS_IP>:3000/api/upload?apiKey=mingchun]
          Method: POST, Request Body: Form
          - photo (File): [Repeat Item]
          - createdAt (Text): [Repeat Item -> Creation Date (ISO 8601)]  (optional)
3. End Repeat
```
*(You can even skip `Generate Hash`, `Get Dictionary Value`, `If`, and `Delete` completely! The backend automatically computes the SHA-256 hash, saves new photos into `/home/ubuntu/gdrive/photoHUB/<user>/YYYY/YYYY-MM-DD/`, and ignores duplicates if the same photo is uploaded again.)*

---

### Workflow A: Upload Photo After Deleting on Device

> **Note on iOS Limitations**: Apple does not allow apps or Shortcuts to read the locked `Recently Deleted` system album or hook directly into the native Trash button inside the Photos app.
> To trigger an upload when/after you delete a photo on your device, use either **Method A1 (Delete First in Shortcut Loop)** or **Method A2 (Share Sheet "Delete & Upload" Action)**:

#### Method A1: Delete on Device First, Then Upload to Server
If you put `Delete` before `Get Contents of URL`, you must first copy the photo file into memory (`Get Images from Input`) so iOS still has the photo bytes after removing it from your camera roll:

```text
1. Find Photos (All Photos, Sort by Creation Date Oldest First, Limit 20)
2. Repeat with each item in [Photos]
     ├─ 2a. Get Images from [Repeat Item]          <-- Keeps photo file in memory before deletion
     ├─ 2b. Generate [SHA-256] hash of [Images]
     ├─ 2c. Delete [Repeat Item]                   <-- User deletes photo on device FIRST (if user cancels, shortcut stops here)
     └─ 2d. Get contents of [http://<VPS_IP>:3000/api/upload?apiKey=mingchun]
              Method: POST, Request Body: Form
              - photo (File): [Images] (output of 2a)
              - createdAt (Text): [Repeat Item -> Creation Date (ISO 8601)]
              - hash (Text): [Hash] (output of 2b)
3. End Repeat
```

#### Method A2: "Delete from iPhone & Upload" from the Photos App Share Sheet
If you want to manually pick photos in the **Photos** app to delete from your iPhone and automatically upload them to your server:
1. Create a new Shortcut named **`Delete & Upload`**.
2. Tap the **`(i)`** info icon at the bottom → turn **ON** **Show in Share Sheet** → set input type to **Images and Media**.
3. Add these actions:
   ```text
   1. Repeat with each item in [Shortcut Input]
        ├─ 1a. Get Images from [Repeat Item]
        ├─ 1b. Generate [SHA-256] hash of [Images]
        ├─ 1c. Delete [Repeat Item]
        └─ 1d. Get contents of [http://<VPS_IP>:3000/api/upload?apiKey=mingchun]
                 Method: POST, Request Body: Form
                 - photo (File): [Images]
                 - createdAt (Text): [Repeat Item -> Creation Date (ISO 8601)]
                 - hash (Text): [Hash]
   2. End Repeat
   ```
4. Now, whenever you want to delete photos in the iPhone **Photos** app to free up space, tap **Share** → **`Delete & Upload`**. It deletes them from your iPhone and uploads them to `/home/ubuntu/gdrive/photoHUB`!

---

### Workflow B: Backup All Photos First, Then Let User Choose to Delete or Keep (No Duplicates on Restart)

This workflow backs up your photos first, skips any photos that were already uploaded in previous runs (zero duplicates), and **asks you at the end** whether you want to delete the backed-up photos or keep them on your iPhone.

#### How Duplicate Prevention Works When You Restart the Shortcut:
1. **Fast Hash Check (`/api/check/[Hash]`)**: Before uploading a photo file, the Shortcut sends just its 64-character SHA-256 hash to the server. If the photo is already on `/home/ubuntu/gdrive/photoHUB` from a previous run (because you chose not to delete it last time), the server replies `exists: true` and the Shortcut **skips uploading the file** (saving time and mobile data!).
2. **Server-Side SHA-256 Deduplication (`/api/upload`)**: Even if the same photo is uploaded again, the server checks `data/hash-index.json`, refuses to write a duplicate file, and returns `"isDuplicate": true, "canDelete": true`.

#### Shortcut Structure (Backup First → Ask User to Delete at the End):

```text
1. Find Photos (All Photos, Sort by Creation Date Oldest First, Limit 50)
2. Repeat with each item in [Photos]
     ├─ 2a. Generate [SHA-256] hash of [Repeat Item]
     ├─ 2b. Get contents of [http://<VPS_IP>:3000/api/check/[Hash]?apiKey=mingchun] (Method: GET)
     ├─ 2c. Get [Value] for [exists] in [Contents of URL]
     ├─ 2d. If [Dictionary Value (as Boolean)] is [true]
     │        └─ Add [Repeat Item] to [BackedUpPhotos]     <-- Already on server! Skip upload.
     ├─     Otherwise
     │        ├─ Get contents of [http://<VPS_IP>:3000/api/upload?apiKey=mingchun] (Method: POST, Body: Form)
     │        │    - photo (File): [Repeat Item]
     │        │    - createdAt (Text): [Repeat Item -> Creation Date (ISO 8601)]
     │        │    - hash (Text): [Hash]
     │        ├─ Get [Value] for [canDelete] in [Contents of URL]
     │        ├─ If [Dictionary Value (as Boolean)] is [true]
     │        │    └─ Add [Repeat Item] to [BackedUpPhotos] <-- Newly uploaded & verified!
     │        └─ End If
     └─     End If
3. End Repeat
4. Choose from Menu: "All photos are backed up to server! Delete from iPhone?"
     ├─ Option 1: "Delete All Backed-Up Photos"
     │    └─ Delete [BackedUpPhotos]
     ├─ Option 2: "Let Me Pick Which Photos to Delete"
     │    ├─ Choose from [BackedUpPhotos] (Select Multiple: ON, Select All Initially: ON)
     │    └─ Delete [Chosen Item]
     └─ Option 3: "Keep All on iPhone"
          └─ (Do nothing — next time you run the Shortcut, these photos won't be duplicated!)
```

> **Simpler Alternative (Skip `/api/check` step)**:
> If you are on fast Wi-Fi and want fewer blocks in your Shortcut, you can omit steps `2b–2d` and just call `POST /api/upload` inside the loop, then `If [canDelete] is true -> Add [Repeat Item] to [BackedUpPhotos]`, and put `Delete [BackedUpPhotos]` after `End Repeat`. The backend automatically deduplicates by SHA-256 so no duplicate files will ever be created on the server!

---

## Part 4: Add the iOS Automation Trigger

1. Open the **Shortcuts** app → **Automation** tab → tap **`+`**.
2. Choose when to trigger:
   - **App** → Choose **Photos** → select **Is Closed** + **Run Immediately** (runs automatically every time you close the Photos app!).
   - **Charger** → **Is Connected** + **Run Immediately**.
   - **Time of Day** → **Daily** + **Run Immediately**.
3. Select your Shortcut.

---

## API Reference Summary

| Endpoint | Method | Auth Required | Description |
| :--- | :--- | :--- | :--- |
| `/api/health` | `GET` | No | Public healthcheck for Docker & browser testing |
| `/api/upload` | `POST` | Yes (if `API_KEY` set) | Accepts `multipart/form-data` or raw binary. Supports `X-Verify-Checksum: strict` for exact SHA-256 confirmation |
| `/api/upload/presign` | `POST` | Yes (if `API_KEY` set) | Returns an S3/MinIO SigV4 pre-signed `PUT` URL when S3 env vars are configured |
| `/api/upload/confirm` | `POST` | Yes (if `API_KEY` set) | Verifies the uploaded S3/MinIO object's SHA-256 and indexes it |
| `/api/check/:hash` | `GET` | Yes (if `API_KEY` set) | Checks if a SHA-256 hash exists as a verified master or registered proxy |
| `/api/check` | `POST` | Yes (if `API_KEY` set) | JSON body `{ "hash": "<sha256>" }` — checks if photo is already backed up |
| `/api/check/batch` | `POST` | Yes (if `API_KEY` set) | JSON body `{ "hashes": [...] }` — batch-checks up to 500 hashes |
| `/api/proxy/register` | `POST` | Yes (if `API_KEY` set) | Registers a compressed local proxy's SHA-256 against a verified master hash |
| `/api/photo/:hash` | `GET` | Yes (if `API_KEY` set) | Streams the full-resolution master photo by `masterHash` or `proxyHash` |

---

## Part 5: Native iOS App (`ios/PhotoHubCompressor`)

For replacing full-resolution iPhone photos with lightweight local proxies after backend checksum confirmation:

1. Open [PhotoHubCompressor.xcodeproj](ios/PhotoHubCompressor/PhotoHubCompressor.xcodeproj) in **Xcode 15+** on macOS (or regenerate with `xcodegen generate` from `ios/PhotoHubCompressor/project.yml`).
2. Select your Development Team in **Signing & Capabilities** and run on your iPhone (iOS 17+).
3. In the **Settings** tab, enter your PhotoHub Server URL, API Key, upload mode (**Direct to VPS** or **S3 / MinIO Pre-signed URL**), and proxy quality/resolution.
4. In the **Compress** tab, tap **Scan Library**, select photos, and tap **Upload & Compress**. The app computes the master SHA-256, uploads the original, waits for strict backend checksum confirmation, and only then replaces the local asset in the Photos app with a lightweight proxy.
