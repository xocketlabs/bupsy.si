# Shipping a release

Everything here works except the parts that need an Apple Developer account. The pipeline is
written, tested where it can be, and waiting on five secrets.

## What you need, once

### 1. Apple Developer account — $99/year

The only unavoidable cost in the project. It gates a downloadable app and the tier 2b wake helper.

From it you need a **Developer ID Application** certificate — *not* a Mac App Store one. bupsy
cannot ship through the App Store at all, because a sandboxed app cannot spawn the `claude` and
`codex` binaries, which is the entire premise. See docs/00-compliance-and-auth.md.

```bash
# After creating the certificate in Xcode → Settings → Accounts → Manage Certificates,
# export it as a .p12 with a password, then:
base64 -i Certificates.p12 | pbcopy      # → CERTIFICATE_P12
security find-identity -v -p codesigning # → DEVELOPER_ID, the full quoted string
```

### 2. An app-specific password for notarization

appleid.apple.com → Sign-In and Security → App-Specific Passwords. Not your Apple ID password.

### 3. Sparkle signing keys

**Not needed yet.** Distribution is GitHub Releases only for now, so there is no appcast feed and
automatic updates stay off — the menu item opens the releases page instead. The signing step in
the workflow is skipped without a key, and the generated appcast ships as a release asset so it is
ready the day a feed gets a home. Set these up when you want updates to install themselves.


```bash
# generate_keys ships with Sparkle; after a build it is in DerivedData
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f | head -1
./generate_keys     # prints the public key, stores the private key in your Keychain
./generate_keys -x sparkle_private_key   # export it for CI, then delete the file
```

The **public** key goes in `project.yml` under `INFOPLIST_KEY_SUPublicEDKey`, replacing the
placeholder. It is meant to be published — it is how a user's copy proves an update came from you.

The **private** key is the one thing in this list that can be used to push arbitrary code to every
user who has installed bupsy. Treat it accordingly: GitHub secret, never a file in the repo, never
in a terminal that logs.

## The five secrets

Repository → Settings → Secrets and variables → Actions:

| Secret | What it is |
|---|---|
| `CERTIFICATE_P12` | base64 of your exported .p12 |
| `CERTIFICATE_PASSWORD` | the password you set when exporting it |
| `DEVELOPER_ID` | `Developer ID Application: Your Name (TEAMID)` |
| `TEAM_ID` | your 10-character team id |
| `NOTARY_APPLE_ID` | the Apple ID used for notarization |
| `NOTARY_PASSWORD` | the app-specific password |
| `SPARKLE_PRIVATE_KEY` | the exported Sparkle private key |

## Releasing

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow then runs tests, signs, notarizes, staples, publishes a GitHub release with the DMG,
and commits an updated `docs/appcast.xml`. Locally, `./scripts/package.sh 0.1.0` does the same
build with the same environment variables — a release process that only works on one machine is
one nobody can verify or take over.

## Things that bite

**Tests gate the release.** A signed, notarized build of broken code is worse than no build: it is
the one people actually install.

**Sparkle's helper tools need signing in their own right.** Signing only the outer bundle passes
locally and fails notarization, which is a slow way to find out. `package.sh` walks
`Contents/Frameworks` first.

**Stapling is not optional.** Without it the DMG works on the machine that built it and fails for
someone opening it on a plane. `package.sh` staples and validates.

**Notarization takes minutes, not seconds.** `--wait` is deliberate; a release that returns before
Apple has answered is a release you cannot trust.

**The appcast carries one item.** A full version history invites someone to install an old build,
and for an app holding agent credentials the oldest build has the known problems.

## Before the first public release

- [x] Licensor named: Xocket Labs Inc., a Delaware corporation
- [ ] Have a lawyer read the Additional Use Grant — the clause that would actually be argued over
- [ ] Agree to Anthropic's Commercial Terms — we run Claude Code in a product
- [ ] *(Later)* Host an appcast and set `SUFeedURL` + `SUPublicEDKey` to switch on auto-updates
- [ ] Sweep every piece of copy for "open source" — it is source-available (docs/02-licence.md)
- [ ] Decide whether the repository goes public at this release
- [ ] Install the DMG on a Mac that has never seen the code, and make sure it opens

## Release checklist

1. `CHANGELOG.md`: move "Unreleased" under the new version, with the date.
2. `project.yml`: set `MARKETING_VERSION`.
3. `./scripts/ci-local.sh` passes, and CI is green on `main`.
4. Run the tour (`--tour` with demo data) and look at every screen in light and dark.
5. Draft first: Actions → Release → Run workflow, version, draft ✓. Download the DMG from the
   draft, install it on a clean user account, and open it.
6. Tag and push (`git tag v0.1.0 && git push --tags`) to publish, or publish the draft.
7. Update `CHECKLIST.md` and the landing page if what ships changed.
