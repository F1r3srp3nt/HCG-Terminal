# Keys, Remote Files and per-host builds

## SSH keys

**Settings → Security → SSH Keys.**

- **Generate Ed25519 Key**: the key is created on the device and kept in the Keychain.
- **Import Private Key…**: from a file (Files app) or the clipboard. The key's contents are never shown.

| Accepted | Not accepted (explained in the app) |
|---|---|
| Ed25519, ECDSA P-256 / P-384 / P-521 | RSA, DSA, security keys (`sk-…`). The SSH library HCG Terminal uses cannot sign in with them. |
| OpenSSH format (`BEGIN OPENSSH PRIVATE KEY`), unencrypted | |
| OpenSSH format with a passphrase: `aes256-ctr` (the `ssh-keygen` default), `aes128-ctr`, `aes192-ctr`, `aes128-gcm@openssh.com`, `aes256-gcm@openssh.com`, with the `bcrypt` key derivation | `chacha20-poly1305@openssh.com`: re-encrypt with `ssh-keygen -p -f <key>` |
| PEM `EC PRIVATE KEY` and PKCS#8 `PRIVATE KEY` (unencrypted) | Encrypted PEM: convert with `ssh-keygen -p -f <key>` |

- **Passphrase:** used once to decrypt the key, then forgotten. The decrypted key is stored in the Keychain like a generated key.
- **Duplicates:** importing the same key twice (same fingerprint) is refused.
- **Decrypting is slow:** the `bcrypt` derivation is deliberately slow (about a second on a phone with `ssh-keygen`'s default 16 rounds), so it runs off the main thread.

**Verification:** `OpenSSHKeyImportTests` generates keys with the real `ssh-keygen` (and `openssl` for PKCS#8 Ed25519) on every run. It checks:

- the fingerprint against `ssh-keygen -lf`;
- the public key against the `.pub` file;
- the `bcrypt_pbkdf` known-answer vector.

`RemoteSSHIntegrationTests.testImportedPassphraseKeysSignIn` signs in to a real OpenSSH server with each imported key type. No private key is committed to the repository.

## Remote Files (SFTP)

**Hosts & Projects → a host → Remote Files (SFTP)** uses the host's SSH connection and its existing host-key check.

- **Browse:** folders first; pull to refresh; go up a level.
- **Download:** saves to the workspace under `downloads/<host>/`.
  - A name already in use gets a number ("report 2.txt"); nothing is overwritten.
  - The file is written to a temporary name and moved into place only when its size matches the remote size.
- **Upload:** pick any workspace file; it goes to the current remote folder.
  - The data is written to a temporary name on the host, checked, then renamed.
  - Replacing an existing file needs confirmation; it is atomic where the server supports `posix-rename@openssh.com`.
- **New Folder.** **Delete:** files and empty folders, with confirmation.
- **Transfers:** shown with progress and Cancel. A cancelled or failed transfer leaves no partial file on either side.
- **Remote SSH switch:** checked before every SFTP request; turning it off stops an open file session.

**Verification:**

- `SFTPProtocolTests`: the SFTP v3 codec.
- `SFTPIntegrationTests`, against OpenSSH:
  - a 1 MiB round trip, compared by SHA-256;
  - a zero-byte file;
  - refusal to replace without confirmation;
  - permission denied and missing paths;
  - cancellation;
  - the access switch.
- `RemoteFilesModelTests`: the whole flow through the app model.

## Per-host builds

**Host settings → Allow builds and tests** (on by default; hosts saved earlier keep it on).

- **When off:** Builds & Tests refuses before connecting. The run is recorded as *could not start*, and nothing is sent to the host.
- **Not affected:** shells, Claude Code sessions and Remote Files.
- **Global switch:** the per-host setting applies in addition to **Remote builds and tests** in Capabilities & Access.

## CI

The **Linux · SSH, SFTP and key import against OpenSSH** job runs in a disposable container:

- it starts `sshd` (`Scripts/start-test-sshd.sh`, SFTP enabled);
- it runs all of the above with `HCG_SSH_TEST=1`.

## Not yet verified

- On a device: the import sheet (Files picker and clipboard), Remote Files, and the progress display.
- Large transfers over a real network (tests use localhost).
