# Google Drive

`home` mounts your Google Drive at `/mnt/gdrive` with
[rclone](https://rclone.org/drive/), as general storage. The files there are
yours (jesse, mode `0600`, directories `0700`); no other user can open them.
The mount comes up by itself once the [secret store](secrets.md) is unlocked
at login, and goes down when it is locked.

Everything about it is declared in
[`hosts/common/optional/gdrive.nix`](../hosts/common/optional/gdrive.nix),
except the three credentials, which live only in the secret store:

| Secret | What it is |
| --- | --- |
| `gdrive-client-id` | Your Google API client's ID |
| `gdrive-client-secret` | That client's secret |
| `gdrive-token` | The OAuth token from signing in, with its refresh token |

They are host secrets owned by a dedicated system user, `gdrive`, which runs
rclone. jesse can't read them, and neither can agents on the host running as
jesse, though they can use the files in the mount like any of yours. Agent
sandboxes get neither the mount nor the credentials.

## One-time setup

Do this after Tohru has switched `home` to a configuration with the mount, and
with the secrets unlocked (you have logged in).

### 1. Create your own Google API client

rclone's shared client is rate-limited across all its users, so use your own.

1. Open the [Google Cloud console](https://console.cloud.google.com/) and
   create a project, for example `rclone-home`.
2. Under **APIs & Services → Library**, find **Google Drive API** and enable
   it.
3. Under **Google Auth Platform** (OAuth consent screen), fill in **Branding**
   with an app name and your email, and set **Audience** to **External**.
4. Still under **Audience**, click **Publish app** so its status is **In
   production**. This matters: a client left in **Testing** issues refresh
   tokens that Google expires after seven days, and the mount would stop
   every week. You don't need Google's verification for your own account.
5. Under **Clients**, create a client of type **Desktop app**. Copy its
   **Client ID** and **Client secret** somewhere you can paste from for the
   next step, such as your password manager. Don't download the JSON file.

### 2. Put the client in the secret store

```sh
secret add gdrive-client-id       # paste the client ID; prompts twice, without echo
secret add gdrive-client-secret   # paste the client secret
```

### 3. Sign in

Run this in a terminal on `home`'s desktop, since Google's approval page
returns to a listener on `127.0.0.1` on this machine:

```sh
gdrive-signin
```

It reads the client from the secret store, opens Google's approval page in
your browser, and waits. Because the client isn't verified, Google first shows
**Google hasn't verified this app**: choose **Advanced**, then **Go to … 
(unsafe)**, and allow access to your Drive. rclone hands the token straight
back to `gdrive-signin`, which checks it has a refresh token and stores it with
`secret add gdrive-token` (or `rotate`, when redoing it). The token never goes
to the screen or a file. Then it runs `secret apply`, which starts the mount.

### 4. Check and back up

```sh
systemctl status gdrive-mount
ls /mnt/gdrive
secret backup /mnt/media3/backups/secrets
```

## Daily behaviour

- **At boot** the secrets are locked, so `gdrive-mount` is skipped and
  `/mnt/gdrive` is an empty directory you can't write to.
- **At login** the secrets unlock and the mount starts a moment later.
- **`secret lock`** stops it. rclone unmounts, and anything still holding a
  file open there gets an error from then on. `secret unlock` brings it back.
- **A missing or withdrawn credential** keeps only this mount down. Switches
  and every other secret's consumers carry on.
- **Without a network** the mount fails to start within 30 seconds and
  retries on its own, waiting a little longer each time, up to five minutes
  between tries, until it gets through. `secret apply` and the login unlock
  can each wait those 30 seconds. Boot and shutdown never wait for the
  network.
- **When the network drops while mounted**, files already in the cache still
  open. New writes go to the cache and upload when the connection returns,
  and listing folders rclone hasn't cached yet fails until then.
- **Uploads in progress at shutdown or `secret lock`** stay in the cache and
  finish the next time the mount starts.
- **Changes made elsewhere**, in the browser or on your phone, show up within
  about a minute.
- **The access token** expires hourly. rclone renews it with the stored
  refresh token and keeps the new one only in its own memory and a private
  tmpfs, `/run/gdrive-mount`, which is rebuilt from the secret store on every
  start. The stored token never changes, and restarts never need you to sign
  in again.

`journalctl -u gdrive-mount` shows rclone's notices and errors.

## The cache

rclone keeps the files you open or write in a cache, so programs can seek and
write as on a local disk. It lives in a 20 GiB image,
`/var/cache/gdrive/cache.img`, on the install drive, mounted at
`/var/cache/gdrive/vfs`. The image is allocated in full when it's created, so
the cache can never take more of the drive than that, and never runs short
because the drive filled up. rclone keeps it under 16 GiB by dropping the
least recently used files, and anything unused for a week.

That cap has consequences:

- A single file you write must fit in the cache's free space, about 19 GiB at
  most. A bigger copy into `/mnt/gdrive` fails with "No space left on device";
  upload it through the browser instead.
- Large copies can briefly fill the cache until rclone uploads and drops
  them, and writes fail until it does.

To change the size, set `gdrive.cache.sizeMiB` in `home`'s configuration and
have Tohru switch. The new size applies once the old image is gone. First
check nothing is waiting to upload, which lists nothing when it's safe:

```sh
sudo grep -rl '"Dirty":true' /var/cache/gdrive/vfs/vfsMeta
```

Then:

```sh
sudo systemctl stop gdrive-mount var-cache-gdrive-vfs.mount
sudo rm /var/cache/gdrive/cache.img
sudo systemctl start gdrive-mount
```

## Limits worth knowing

- **Uploads are capped at about 750 GB a day** per Google account. Past it,
  uploads fail until the next day, and they wait in the cache meanwhile.
- **Many small files are slow.** Every file is at least one request to Google,
  and Google rate-limits them, so a folder of thousands of small files takes
  minutes to copy. Don't keep Git repositories, build trees, databases or
  application state here; archive such folders into one file first.
- **It isn't a POSIX filesystem.** There are no symlinks, hard links,
  ownership or permission bits (everything shows as jesse's), and Drive allows
  two files with the same name in one folder, which rclone shows once.
- **Google Docs, Sheets and Slides** appear as exported `.docx`, `.xlsx` and
  `.pptx` files. Editing those copies doesn't edit the originals.
- **The cache holds your files' contents** on the install drive, unencrypted,
  readable only by `gdrive` and root.

## Signing in again

If the mount stops with `invalid_grant` or "token expired" in
`journalctl -u gdrive-mount`, the refresh token no longer works. That happens
when you revoke the app's access in your Google account's security settings,
when the client was left in **Testing** (seven days), or when the token goes
unused for six months. Run the sign-in again:

```sh
gdrive-signin
```

It replaces `gdrive-token` and restarts the mount. Each sign-in issues a new
refresh token; Google keeps the newest 100 per client and revokes older ones
on its own, so there's nothing to clean up. Back the secret file up afterwards.

To replace the client secret, add a new one to the client in the Cloud
console, then:

```sh
secret rotate gdrive-client-secret
secret apply
```

Check the mount works, then delete the old secret in the console. A new
client (a new client ID) needs `secret rotate gdrive-client-id` as well, and a
new sign-in, since refresh tokens belong to the client that issued them.

## Turning it off

Set `gdrive.enable = false` for `home` and have Tohru switch, then remove the
credentials with `secret remove` for each of the three, revoke the app's
access in your Google account, and delete `/var/cache/gdrive` once nothing is
waiting to upload.
