#!/bin/bash
# Writes the appcast Sparkle polls for updates.
#
# Deliberately a single-item feed. A full version history invites someone to install an old build,
# and for an app that holds agent credentials the oldest build is the one with the known problems.
set -euo pipefail

VERSION="${1:?usage: appcast.sh <version> <signature> <dmg>}"
SIGNATURE="${2:-}"
DMG="${3:?}"
REPO="${REPO:-vanshpatelx/bupsy.si}"

LENGTH=$(stat -f%z "$DMG" 2>/dev/null || stat -c%s "$DMG")
DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bupsy</title>
    <link>https://github.com/$REPO</link>
    <description>Updates for Bupsy</description>
    <language>en</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure
        url="https://github.com/$REPO/releases/download/v$VERSION/Bupsy-$VERSION.dmg"
        length="$LENGTH"
        type="application/octet-stream"
        sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
XML
