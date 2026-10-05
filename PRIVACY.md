# Privacy Policy for Strakaláři

**Last updated:** October 2, 2026

Strakaláři is an open-source, local desktop application designed to help students manage school schedules, absences, and lunches. Your privacy is paramount: **the application operates locally on your machine and does not collect, track, or sell your personal data.**

---

### 1. Information Handled by the Application

Strakaláři processes the following information strictly to perform the actions you configure:

* **Authentication Credentials:** Usernames and passwords for your school's Bakaláři system and Strava.cz account.
* **School & Timetable Data:** Timetables, attendance records, absences, and grades fetched directly from your school's Bakaláři instance.
* **Lunch & Dining Data:** Menus, orders, balances, and blacklist preferences fetched from and submitted to Strava.cz.
* **Application Settings:** Automation preferences, chosen school presets, and UI settings.

---

### 2. Where Data Is Stored & Security

* **Local Storage Only:** All configuration, caches, and logs reside solely on your local device: on Windows in `%LOCALAPPDATA%\Programs\Strakalari` (installer version) or `%LOCALAPPDATA%\Strakalari` (Microsoft Store version, kept by Windows in the app's private package folder).
* **Credential Encryption:** Passwords are encrypted before saving. The encryption key is protected using the operating system's native credential management / DPAPI mechanisms.
* **No Developer Access:** The developer(s) of Strakaláři have **no access** to your credentials, school data, or activity logs.

---

### 3. Network Communication & Third Parties

Strakaláři only connects to the internet to perform the services you request:

1. **Your School's Bakaláři Server:** Directly connects to your school's official Bakaláři web portal to synchronize timetable and absence data.
2. **Strava.cz:** Directly connects to the official Strava.cz portal to retrieve menus and place lunch orders.
3. **Google Gemini API (Optional):** Only if you explicitly activate AI lunch recommendations and provide an API key, dish names and meal preferences are sent to Google Gemini to generate recommendations.
4. **GitHub Releases API (installer version only):** Periodically checks `api.github.com` for application updates. No identifying information is transmitted. The Microsoft Store version is updated by the Store and never contacts GitHub.
5. **Browser download:** On first use, the app downloads the Chromium browser it automates from Playwright's official download servers. No personal data is sent.
6. **No Telemetry or Tracking:** The application contains **no third-party tracking scripts, advertising SDKs, or remote analytics**.

---

### 4. Logging & Diagnostics

* Logs (`log.txt`, `console.log`) are stored locally on your device for troubleshooting.
* The built-in *Live Log* feature automatically strips passwords, usernames, and personal signatures before copying, allowing you to report bugs safely.

---

### 5. Data Deletion

You can delete all data and credentials at any time by uninstalling the application and confirming data removal, or by deleting the application data directory from your local system. Uninstalling the Microsoft Store version removes its data automatically.

---

### 6. Contact

If you have questions regarding this policy or the application's security, you can open an issue on GitHub:
https://github.com/DeNdlerX/strakalari/issues
