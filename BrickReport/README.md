# BrickReport (Screen Time stats extension)

iOS only lets a Device Activity Report extension read usage numbers. One-time Xcode setup:

1. File > New > Target > Device Activity Report Extension. Name it BrickReport.
2. Delete the generated Swift files and add BrickReport.swift from this folder to that target.
3. Under Signing & Capabilities on the BrickReport target, add Family Controls.
4. Build and run the app. The Stats page shows the report below the Brick numbers.

Until the extension exists, the Screen Time block on the Stats page is blank. Brick's own stats (sessions, focus time, streak) work without it.
