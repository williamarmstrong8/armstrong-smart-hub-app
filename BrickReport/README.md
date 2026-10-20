# BrickReport (Screen Time stats extension)

iOS only lets a Device Activity Report extension read usage numbers. One-time Xcode setup:

1. File > New > Target > Device Activity Report Extension. Name it BrickReport.
2. Delete the generated Swift files and add BrickReport.swift from this folder to that target.
3. Under Signing & Capabilities on the BrickReport target, add Family Controls.
4. Build and run the app. The Brick tab shows it when you open the Screen Time row.

Until the extension exists, the Screen Time block on the Brick tab is blank. Brick's own stats (sessions, focus time, streak) work without it.
