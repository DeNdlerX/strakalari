# Installing Strakaláři on iPhone (sideloading)

Strakaláři for iOS is currently for **internal testing only** — it is not on the Apple App Store. Instead, you install an unsigned `.ipa` file built by GitHub Actions onto your iPhone ("sideloading") using your own Apple ID.

> **Status (not yet tested on an iPhone):** Today, Timetable, Absences & Planner, Marks, Lunches, Activity, Settings, the setup wizard, multiple accounts, and iOS Keychain password encryption are wired up and expected to work on iOS, but this build has not yet been built on a Mac or opened on a real iPhone.
>
> **What is Android-only for now:** Running in the background while the app is closed, the morning wake-up alarm, the home-screen schedule widget, and notifications are not enabled on iOS yet. Data refreshes while the app is open.

---

## Step 1: Get the `.ipa` file from GitHub

1. Open the repository on GitHub and click **Actions**.
2. Open the **Dart** workflow and click a release run (a `v*` tag or a manual run started with a `release_tag`).
3. Scroll down to **Artifacts** and download **`flutter-ios-unsigned`**.
4. Unzip the downloaded archive to get `Strakalari-<version>-ios-unsigned.ipa`.

> **Note:** GitHub deletes the `.ipa` **14 days** after the run. A new one is built only together with a new release (a new `v…` version, for example a new beta), because every run that builds it also publishes that release. Never start a run with the tag of a version that's already out: it would change that release.

---

## Step 2: Install it on your iPhone

Pick whichever option fits the computer you have.

### Option A: Sideloadly (Windows or Mac — easiest)

You do **not** need a Mac or Xcode for this method.

1. Download and install [Sideloadly](https://sideloadly.io/) on Windows or macOS (on Windows, also install the web version of iTunes and iCloud from Apple — not the Microsoft Store versions — if Sideloadly asks for them).
2. Connect your iPhone to your computer with a USB cable and tap **Trust** on the iPhone if asked.
3. Open Sideloadly:
   - Drag `Strakalari-<version>-ios-unsigned.ipa` onto the **IPA** box.
   - Make sure your iPhone appears under **iDevice**.
   - Enter your **Apple ID** (a normal free Apple ID works).
   - Click **Start** and enter your Apple ID password / two-factor code when prompted.
4. Wait until Sideloadly says **Done**. The Strakaláři icon will appear on your iPhone's Home Screen.
5. Finish Step 3 below before opening the app.

### Option B: AltStore or SideStore (automatic 7-day refresh)

If you already use [AltStore](https://altstore.io/) or [SideStore](https://sidestore.io/):

1. Send `Strakalari-<version>-ios-unsigned.ipa` to your iPhone (AirDrop, iCloud Drive, or Files).
2. Open **AltStore** (or **SideStore**), go to **My Apps**, tap **`+`**, and pick the `.ipa` file.
3. Keep AltServer running on your computer (or SideStore configured on Wi-Fi) so the app refreshes automatically before the 7-day free-account limit expires.

### Option C: Mac + Xcode (best for testing and reading crash logs)

Use this option if you have access to a Mac with Xcode and **Flutter 3.44.8** installed and want live console logs.

1. Clone the repository on the Mac, install dependencies at the repository root, and generate the Xcode Flutter config inside `app/`:
   ```bash
   dart pub get --enforce-lockfile
   cd app
   flutter pub get
   flutter build ios --config-only --no-codesign
   ```
   (This creates `app/ios/Flutter/Generated.xcconfig`, which Xcode needs before it can build.)
2. Open **`app/ios/Runner.xcworkspace`** in Xcode (open the `.xcworkspace`, not `.xcodeproj`).
3. Click **Runner** in the left sidebar → **Signing & Capabilities**:
   - Check **Automatically manage signing**.
   - Pick your personal Apple ID under **Team**.
   - The default Bundle Identifier is `io.github.dendlerx.strakalari`. If Xcode says that identifier is already registered to another Apple ID team, change it slightly (for example `io.github.dendlerx.strakalari.jk`).
4. Connect the iPhone by USB, select it as the run destination at the top of Xcode, and click **Run (`▶`)**.

---

## Step 3: Trust the app on your iPhone (first time only)

The first time you tap Strakaláři, iOS will ask you to trust your developer profile and enable Developer Mode:

1. **Trust your Apple ID:**
   - Open **Settings → General → VPN & Device Management**.
   - Under *Developer App*, tap your Apple ID and tap **Trust**.
2. **Turn on Developer Mode (iOS 16 and newer):**
   - Open **Settings → Privacy & Security → Developer Mode**.
   - Switch **Developer Mode** on and restart the iPhone when asked.
   - After restarting, tap **Turn On** and enter your iPhone passcode.

Now tap **Strakaláři** on your Home Screen — it should open normally.

---

## Keeping it working & keeping your data

- **7-day renewal (free Apple ID):** Apps sideloaded with a free Apple ID stop opening after 7 days. To renew or update to a newer version, install the `.ipa` again with the **same Apple ID** (and the same Bundle Identifier) **without uninstalling** the app first. Your saved accounts, settings, and Keychain encryption keys are designed to stay intact across that reinstall (Keychain names do not depend on the changing iOS container path), though this is untested until the first renewal on a real iPhone.
- **Paid Apple Developer account ($99/year):** If signed with a paid Apple Developer account, the app stays valid for a full year instead of 7 days.
- **Uninstalling wipes local data:** Removing the app from your iPhone deletes its saved data folder on the phone.
- **Privacy:** Your Bakaláři and Strava.cz credentials stay on your iPhone and are encrypted with a key stored in the iOS Keychain; nothing is sent anywhere except your school's Bakaláři server and Strava.cz.

---

## Common problems

- **"Untrusted Developer"** → Complete **Settings → General → VPN & Device Management → Trust**.
- **"Developer Mode Required"** → Turn on **Settings → Privacy & Security → Developer Mode** and restart the phone.
- **"Strakaláři is no longer available"** → The 7-day free Apple ID signature expired. Re-install the `.ipa` over the existing app using the same Apple ID.
- **"Maximum number of apps for free development profiles has been reached"** → Apple limits free Apple IDs to 3 sideloaded apps active at once. Remove another sideloaded app (or use a paid Developer account) and try again.
