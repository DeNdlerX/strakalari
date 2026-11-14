# Privacy Policy for Strakaláři

**Last updated:** November 14, 2026

Strakaláři is an open-source, local application for Windows, macOS, Linux and Android designed to help students manage school schedules, absences, and lunches. Your privacy is paramount: **the application operates locally on your device and does not collect, track, or sell your personal data.**

---

### 1. Information Handled by the Application

Strakaláři processes the following information strictly to perform the actions you configure:

* **Authentication Credentials:** Usernames and passwords for your school's Bakaláři system and Strava.cz account.
* **School & Timetable Data:** Timetables, attendance records, absences, and grades fetched directly from your school's Bakaláři instance.
* **Lunch & Dining Data:** Menus, orders, balances, and blacklist preferences fetched from and submitted to Strava.cz.
* **Application Settings:** Automation preferences, chosen school presets, and UI settings.

---

### 2. Where Data Is Stored & Security

* **Local Storage Only:** All configuration, caches, and logs reside solely on your local device: on Windows in `%LOCALAPPDATA%\Programs\Strakalari` (installer version) or `%LOCALAPPDATA%\Strakalari` (Microsoft Store version, kept by Windows in the app's private package folder), on macOS in `~/Library/Application Support/Strakalari` and on Linux in `~/.config/strakalari`. `STRAKALARI_DATA_DIR` overrides all of them.
* **Android:** All data resides in the app's private storage on your phone, which other apps cannot access. Android backup is disabled for the app, so the data is not uploaded to Google's cloud backup.
* **Upgrading between versions:** updating the app installs over the previous version and continues using the same local data folder and file formats. Settings, saved passwords, and absence history carry over automatically on your device without any extra migration step, and nothing leaves your device during the update. What the app connects to (§3) does not change.
* **Credential Encryption:** Passwords are encrypted before saving. The encryption key is stored in the platform's native credential store when available: Windows Credential Manager on Windows, Apple Keychain on macOS, Secret Service (via `secret-tool`, bundled in the AppImage) on Linux, and Android Keystore on Android. If the operating system credential store is unavailable (for example on a headless desktop session), the app falls back to a local `secret.key` file stored alongside the encrypted passwords in its private data directory.
* **No Developer Access:** The developer(s) of Strakaláři have **no access** to your credentials, school data, or activity logs.

---

### 3. Network Communication & Third Parties

Strakaláři only connects to the internet to perform the services you request:

1. **Your School's Bakaláři Server:** Directly connects to your school's official Bakaláři web portal to synchronize timetable and absence data.
2. **Strava.cz:** Directly connects to the official Strava.cz portal to retrieve menus and place lunch orders.
3. **Google Gemini API (Optional):** Only if you explicitly activate AI lunch recommendations and provide an API key, dish names and meal preferences are sent to Google Gemini to generate recommendations.
4. **GitHub Releases API (installer version only):** Periodically checks `api.github.com` for application updates. No identifying information is transmitted. The Microsoft Store version is updated by the Store and the Android version by Google Play; neither contacts GitHub.
5. **No Telemetry or Tracking:** The application contains **no third-party tracking scripts, advertising SDKs, or remote analytics**.

---

### 4. Logging & Diagnostics

* Logs (`log.txt`, `console.log`) are stored locally on your device for troubleshooting.
* The built-in *Live Log* feature automatically strips passwords, usernames, and personal signatures before copying, allowing you to report bugs safely.

---

### 5. Data Deletion

You can delete all data and credentials at any time by uninstalling the application and confirming data removal, or by deleting the application data directory from your local system. Uninstalling the Microsoft Store version removes its data automatically. On Android, clearing the app's storage in system settings or uninstalling the app removes all of its data.

---

### 6. Contact

If you have questions regarding this policy or the application's security, you can write to **dendlerx@gmail.com** or open an issue on GitHub:
https://github.com/DeNdlerX/strakalari/issues
