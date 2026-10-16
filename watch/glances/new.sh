#!/usr/bin/env bash
# Scaffolds a glance project: glances/new.sh <Folder> <Entry class> "<Display name>"
set -euo pipefail
cd "$(dirname "$0")"
dir="$1"; entry="$2"; name="$3"
mkdir -p "$dir/source" "$dir/resources/drawables" "$dir/resources/strings"
cp ../ArmstrongFace/resources/drawables/* "$dir/resources/drawables/"
printf '<resources>\n    <string id="AppName">%s</string>\n</resources>\n' "$name" > "$dir/resources/strings/strings.xml"
printf 'project.manifest = manifest.xml\nbase.sourcePath = source;../../shared\n' > "$dir/monkey.jungle"
cat > "$dir/manifest.xml" <<XML
<?xml version="1.0"?>
<iq:manifest xmlns:iq="http://www.garmin.com/xml/connectiq" version="3">
    <iq:application entry="$entry" id="$(uuidgen | tr A-Z a-z)" launcherIcon="@Drawables.LauncherIcon" name="@Strings.AppName" type="widget" minApiLevel="4.2.0">
        <iq:products>
            <iq:product id="fr965"/>
        </iq:products>
        <iq:permissions>
            <iq:uses-permission id="SensorHistory"/>
            <iq:uses-permission id="UserProfile"/>
        </iq:permissions>
        <iq:languages>
            <iq:language>eng</iq:language>
        </iq:languages>
        <iq:barrels/>
    </iq:application>
</iq:manifest>
XML
