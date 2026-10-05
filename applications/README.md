# Optional programs

Application source modules live in core/, desktop/, perfmon/, and system-tools/.
The core/ modules are needed by WindowManager, PET, and startup. The other
programs and their data files are excluded from the minimal runtime image.

Build a normal target first, then run:

    python applications/manage.py build --platform Win64 --build target/Win64 --output target/Win64-mini

This creates target/Win64-mini and ZIPs in applications/packages/Win64.
Start target/Win64-mini/a2.bat. The core desktop opens PET. Install a local
package with:

    python applications/manage.py install target/Win64-mini desktop

The installer also accepts an explicit ZIP filename or HTTPS URL. Restart A2
after installing or removing a package. Installed modules, sources, and assets
are kept under apps/<name>/ and added to A2's search path in apps.cfg.

The local catalog contains clock, calendar, diff, desktop, perfmon, and system-tools. Installing desktop pulls in clock, calendar, and diff. desktop holds
the optional resources moved from data/. They remain in this repository so
normal development builds can still compile the full package list.

A third-party package is a ZIP with a2app.json plus flat bin/, data/, and/or
source/ files. Use `python applications/manage.py pack STAGING OUTPUT.zip` to
create it. The manifest needs format=minia2-app-v1, a simple name, version,
platform, optional requires and commands. The packer adds SHA-256 checksums.
Native code is platform-specific; build a ZIP for each target.
