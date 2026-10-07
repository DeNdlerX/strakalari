# Microsoft Store (MSIX)

**Proč MSIX a ne .exe:** Store listing typu „EXE or MSI“ chce instalátor
podepsaný placeným certifikátem a odkaz, odkud si ho Store stáhne. MSIX se
naopak nahrává **přímo do Partner Center** a podepíše ho Store sám — žádný
certifikát ani hosting (GitHub, Google Drive…) není potřeba.

**Jak to funguje:** tag `vX.Y.Z` → CI postaví `Strakalari.exe` → job
`build-msix` z něj udělá nepodepsaný `.msix` (artefakt `msix-package`
u běhu workflow) → ty ho nahraješ v Partner Center (nebo, volitelně, job
`publish-store` přes API). MSIX se **nepřikládá do GitHub Releases**
(nepodepsaný se mimo Store nainstalovat nedá) a bety do Storu nejdou.

## 1. Jednorázově: aplikace v Partner Center

1. Existující produkt typu **EXE or MSI app** nejde na MSIX přepnout.
   Pokud nikdy nebyl publikovaný, smaž ho (uvolní se tím jméno); jinak
   požádej podporu Partner Center o změnu typu balíčku.
2. **Apps and games → New product → MSIX or PWA app** → rezervuj jméno
   Strakaláři.
3. **Product management → Product identity**: zkopíruj tři hodnoty do
   `.github/workflows/build.yml` (job `build-msix`, blok `env:`) a commitni.
   Nejsou tajné (jsou vidět v každém nainstalovaném balíčku):

   | Partner Center                          | `build.yml`               |
   |-----------------------------------------|---------------------------|
   | Package/Identity/Name                   | `STORE_IDENTITY_NAME`     |
   | Package/Identity/Publisher (`CN=…`)     | `STORE_PUBLISHER`         |
   | Package/Properties/PublisherDisplayName | `STORE_PUBLISHER_DISPLAY` |

   Bez nich CI postaví balíček s testovací identitou, který Partner Center
   odmítne (workflow na to upozorní warningem).

## 2. Každé vydání (ručně, pár minut)

1. Pushni tag `vX.Y.Z` (bez `-beta`; verze musí s každým odesláním růst).
2. Po doběhnutí workflow: **Actions → běh → Artifacts → `msix-package`**
   → stáhni a rozbal; uvnitř je `Strakalari-X.Y.Z.msix`.
3. Partner Center → aplikace → **Start submission** (příště **Update**)
   → **Packages** → přetáhni `.msix`. Partner Center ho hned zvaliduje.
4. **Jen poprvé** vyplň zbytek submission:
   - *Pricing and availability*, *Properties* (kategorie; **Privacy policy
     URL** = odkaz na `PRIVACY.md` na GitHubu), *Age ratings*;
   - *Store listings* **pro češtinu i angličtinu** — manifest deklaruje
     `cs-cz` i `en-us`, takže Store chce obě; aspoň jeden screenshot
     (`docs/images`);
   - *Submission options → Restricted capabilities*: zdůvodni
     `runFullTrust`, např. „Desktop app written in Python, packaged as
     MSIX; runs as a full-trust Win32 process.“
5. **Submit to the Store.** Certifikace trvá hodiny až dny, výsledek
   přijde mailem.

## 3. Volitelně: automatické odesílání z CI

Až je první submission **publikovaná** (API jinak nefunguje), může krok 2
dělat job `publish-store` sám. Bez secretů jen zanechá notice a nic
neodesílá.

1. V [Entra admin center](https://entra.microsoft.com) vytvoř **App
   registration** (např. `strakalari-store`), v *Certificates & secrets*
   **client secret** (hodnota se ukáže jen jednou) a poznamenej si
   **Application (client) ID** a **Directory (tenant) ID**.
2. Partner Center: **Account settings → Tenants** → přidruž tenanta;
   **User management → Azure AD applications → Add** → vyber aplikaci,
   role **Manager**.
3. GitHub → repo → Settings → Secrets → Actions:

   | Secret                | Co to je                                        |
   |-----------------------|-------------------------------------------------|
   | `STORE_TENANT_ID`     | Directory (tenant) ID                           |
   | `STORE_CLIENT_ID`     | Application (client) ID                         |
   | `STORE_CLIENT_SECRET` | hodnota client secretu                          |
   | `STORE_APP_ID`        | Store ID aplikace (Product identity, `9N…`)     |

Job naklonuje poslední publikovanou submission (popis, ceny, screenshoty
zůstanou), vymění balíček a odešle k certifikaci. Zkouška nanečisto
(nahraje, zkontroluje, draft smaže):

```powershell
$env:STORE_TENANT_ID="..."; $env:STORE_CLIENT_ID="..."; $env:STORE_CLIENT_SECRET="..."; $env:STORE_APP_ID="..."
python tools/store_submit.py Strakalari-X.Y.Z.msix --discard
```

## Vyzkoušení balíčku před odesláním

Potřeba Windows SDK (`MakeAppx.exe`) a pro instalaci zapnutý **Režim pro
vývojáře** (Nastavení → Systém → Pro vývojáře):

```powershell
pyinstaller strakalari.spec
python tools/make_msix.py --exe dist/Strakalari.exe --out Strakalari-test.msix `
  --version 0.2.0 --identity-name "Strakalari.Placeholder" `
  --publisher "CN=Strakalari-Placeholder" --publisher-display "Strakalari" `
  --layout msix-layout
Add-AppxPackage -Register .\msix-layout\AppxManifest.xml
```

Spusť z nabídky Start (jen tak běží s identitou balíčku) a ověř: uložení
nastavení, stažení prohlížeče, přihlášení, a autostart (Nastavení →
Aplikace → Po spuštění → zapnout → odhlásit/přihlásit → má naběhnout
v tray). Odinstalace: `Get-AppxPackage *Strakalari* | Remove-AppxPackage`.

## Chování Store buildu (stejné exe jako v Setupu)

- **Aktualizace** spravuje Store: kanál, banner i „Zkontrolovat
  aktualizace“ jsou skryté a GitHub se nekontroluje.
- **Autostart** přes StartupTask v manifestu (výchozí stav vypnuto):
  zapíná se ve Windows (Nastavení → Aplikace → Po spuštění), tlačítko
  v nastavení aplikace tam vede. Startuje rovnou do tray (`--minimized`).
- **Data** v `%LOCALAPPDATA%\Strakalari` — fyzicky je Windows drží
  v soukromé složce balíčku
  (`%LOCALAPPDATA%\Packages\<balíček>\LocalCache\Local\…`) a při
  odinstalaci je smaže. Složka s exe je jen pro čtení, nic se do ní
  nezapisuje.
- **První start** převezme data z klasické instalace
  (`%LOCALAPPDATA%\Programs\Strakalari`) včetně klíče k heslům, pokud
  Store verze ještě nemá vlastní `config.json`. Klasická instalace zůstane
  — **odinstaluj ji**, jinak běží automatizace dvakrát (dvojí objednávky,
  dvojí omluvenky).

## Když něco selže

- `build-msix` warning o identitě → doplň hodnoty z kroku 1.3.
- Partner Center odmítne balíček kvůli identitě/publisherovi → hodnoty
  v `build.yml` neodpovídají *Product identity*.
- `publish-store`: `401` → expirovaný/špatný client secret nebo aplikace
  nemá v Partner Center roli; „no published submission“ → první
  submission musí projít ručně; „draft submission … is already open“ →
  dokonči nebo smaž rozpracovanou submission v Partner Center.
- Certifikace zamítnuta → důvod je v Partner Center a v mailu; typicky
  chybí listing (popis, screenshoty, kategorie) nebo zdůvodnění
  `runFullTrust`.
