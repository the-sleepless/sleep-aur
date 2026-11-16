# AUR packaging

This directory contains the AUR package definition for `sleep-aur`.

The GitHub repository is the source of truth. On every release, update `pkgver`,
both checksums, and regenerate `.SRCINFO`.

## Publishing

1. Create an AUR account and add your SSH public key at
   <https://aur.archlinux.org/account/>.
2. Clone the AUR repository:

   ```bash
   git clone ssh://aur@aur.archlinux.org/sleep-aur.git
   ```

3. Copy `PKGBUILD` and `.SRCINFO` into the AUR checkout.
4. Regenerate `.SRCINFO` on Arch:

   ```bash
   makepkg --printsrcinfo > .SRCINFO
   ```

5. Validate and commit:

   ```bash
   makepkg --verifysource
   git add PKGBUILD .SRCINFO
   git commit -m "sleep-aur 3.1.7-1"
   git push
   ```

## Updating for a new release

1. Set `pkgver` in `PKGBUILD`.
2. Update the checksums:

   ```bash
   curl -fsSL "https://github.com/the-sleepless/sleep-aur/releases/download/v3.1.8/sleep-aur.tar.gz.sha256"
   curl -fsSL "https://raw.githubusercontent.com/the-sleepless/sleep-aur/v3.1.8/LICENSE" | sha256sum
   ```

3. Regenerate `.SRCINFO`:

   ```bash
   makepkg --printsrcinfo > .SRCINFO
   ```

4. Commit and push to the AUR repository.
