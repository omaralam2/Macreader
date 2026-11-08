# MacReader

تطبيق صغير في شريط القوايم (Menu Bar) على الماك، بيخلّيك **تقرا وتكتب** على هارد خارجي متفرمت **NTFS** (الفورمات بتاع ويندوز).
الماك لوحده بيقرا NTFS بس ومبيكتبش عليه.

> A small macOS menu-bar app that makes external **NTFS** drives writable, using ntfs-3g + FUSE-T (no kernel extension) or macFUSE, with data safety as the first priority. English summary at the bottom.

---

## بيشتغل إزاي؟

MacReader **مبيكتبش على الهارد بنفسه**. الكتابة بتعدّي من [ntfs-3g](https://github.com/tuxera/ntfs-3g)، وده درايفر NTFS مستخدم في لينكس من سنين،
وشغّال على الماك عن طريق [FUSE-T](https://www.fuse-t.org) (الأساس: من غير kernel extension) أو [macFUSE](https://osxfuse.github.io). التطبيق بيعمل كده:

1. يكتشف أي هارد NTFS أول ما يتوصل.
2. لما تدوس **«افتح للكتابة»**، يطلب باسورد الماك، ويفك الـ mount اللي قراءة فقط، ويركّب الهارد تاني بـ ntfs-3g للقراءة والكتابة.
3. لما تدوس **Eject**، يحفظ كل حاجة ويفصل الهارد بأمان.

## حماية الداتا 🛡️

- **قراءة فقط هي الأساس.** مفيش كتابة غير لما تدوس الزرار بنفسك. خاصية الفتح التلقائي مقفولة من الأول.
- **مفيش إصلاح ولا فرمتة خالص.** التطبيق مفيهوش أي أمر `format` أو `ntfsfix` أو `chkdsk`، ومبيمسحش ملف الـ Hibernate بتاع ويندوز.
- **بيرفض الهاردات اللي مقفلتش صح.** الـ mount بيتعمل بـ `-o norecover`. لو ويندوز سايب الهارد في Fast Startup أو Hibernate، أو الهارد اتشال من غير Eject، ntfs-3g بيرفض يفتحه للكتابة والتطبيق بيرجّعه قراءة فقط.
- **بيتأكد إنه NTFS بجد.** قبل أي mount بيقرا توقيع الـ boot sector. لو مش `NTFS` (زي BitLocker)، مبيلمسش الهارد ويرجّعه قراءة فقط.
- **مبيقولش «اتفتح للكتابة» غير لما يشوف mount حقيقي.** لو ntfs-3g خلص من غير ما يركّب الهارد (مثلاً الدرايفر مش شغّال)، التطبيق بيشيل الفولدر الفاضي وبيقولك، علشان متكتبش على هارد الماك وانت فاكر إنك بتكتب على الهارد الخارجي.
- **مفيش Eject بالعافية.** الفصل بيتعمل من غير `force`. لو فيه ملف مفتوح، الفصل بيفشل والتطبيق يقولك أنهي برنامج فاتحه.
- **بيستنى الكتابة تخلص.** قبل ما يفصل الهارد بيستنى ntfs-3g يخلّص كتابة كل الداتا ويقفل، وبعدين بس يعمل Eject.
- **بيفتكر لو الهارد اتشال فجأة.** لو الهارد اتشال وهو مفتوح للكتابة، المرة الجاية مش هيتفتح للكتابة لحد ما تعمله `chkdsk` على ويندوز.
- **تحذير قبل ما تقفل التطبيق** لو فيه هارد لسه مفتوح للكتابة.

> ⚠️ **بصراحة:** مفيش أداة تضمن 100%. خلّي عندك نسخة احتياطية من الحاجات المهمة، وجرّب التطبيق الأول على هارد مفيهوش حاجة مهمة.

## المتطلبات

- macOS 13 (Ventura) أو أحدث. اتجرّب على macOS 27 على Apple Silicon.
- [Homebrew](https://brew.sh).
- Xcode أو Command Line Tools: `xcode-select --install`.

## التسطيب خطوة بخطوة

الطريقة دي بتستخدم **FUSE-T**: مش محتاجة kernel extension ولا Reduced Security ولا Restart.
FUSE-T بيشغّل سيرفر NFS صغير على جهازك، والماك بيشوف الهارد كأنه هارد شبكة.
كل خطوة فيها `sudo` هتطلب باسورد الماك. وانت بتكتبه في الـ Terminal مش هيظهر حاجة، وده طبيعي.

**1. نزّل المشروع:**
```sh
git clone https://github.com/omaralam2/Macreader.git ~/Macreader
cd ~/Macreader
```

**2. سطّب FUSE-T:**
```sh
sudo mkdir -p /usr/local/include /usr/local/lib
brew trust --cask macos-fuse-t/cask/fuse-t
brew install --cask macos-fuse-t/cask/fuse-t
```

**3. ابني ntfs-3g على FUSE-T** (السكربت بيبني [نسخة FUSE-T من ntfs-3g](https://github.com/macos-fuse-t/ntfs-3g) ويسطّبها في `/usr/local/bin/ntfs-3g`، ومش بيلمس أي ntfs-3g تاني عندك):
```sh
./scripts/install_ntfs3g_fuse_t.sh
```
لما يخلص هيكتب `✅ Installed` وتحته `libfuse-t.dylib`.

**4. ابني التطبيق:**
```sh
./scripts/build_app.sh
```
لو عندك شهادة مطوّر من Apple، ابني بيها بدل كده، علشان إذن Full Disk Access ميضيعش كل ما تبني من جديد
(البناء العادي بيعمل توقيع محلي ad-hoc بيتغيّر كل مرة):
```sh
security find-identity -v -p codesigning   # اعرف اسم شهادتك
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build_app.sh
```

**5. اديله Full Disk Access:** التطبيق محتاج يقرا الهارد مباشرة.
افتح **System Settings ← Privacy & Security ← Full Disk Access**، دوس **+**، واختار `~/Macreader/build/MacReader.app`، وفعّله.

**6. شغّله:**
```sh
open ~/Macreader/build/MacReader.app
# أو انقله لمجلد التطبيقات (وساعتها اديه Full Disk Access من هناك):
cp -R ~/Macreader/build/MacReader.app /Applications/
```
هيظهر رمز هارد 🖴 في شريط القوايم فوق. لو حاجة من الخطوات ناقصة، التطبيق هيوريك هي إيه وفيه زرار تنسخ بيه الأمر.

> FUSE-T مجاني للاستخدام الشخصي. لو هتوزّع التطبيق تجارياً لازم رخصة من أصحاب FUSE-T (ونفس الكلام لـ macFUSE). ntfs-3g مفتوح المصدر (GPL).

### البديل: macFUSE

لو عايز تستخدم macFUSE بدل FUSE-T:
```sh
brew install --cask macfuse
brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac
```
محتاج تسمح بالـ kernel extension، وعلى أجهزة **Apple Silicon** لازم **Reduced Security** من Recovery Mode.
على macOS 26/27 طريقة FSKit بتاعة macFUSE فيها مشكلة معروفة لسه متحلّتش ([#1194](https://github.com/macfuse/macfuse/issues/1194))، علشان كده FUSE-T هو الأساس.
لو الاتنين متسطّبين، التطبيق بيستخدم FUSE-T، وكل نسخة ntfs-3g بتشتغل بس مع الدرايفر اللي اتبنت عليه.

## الاستخدام

1. وصّل الهارد. هيظهر في القائمة وجنبه **«قراءة فقط»**.
2. دوس **«افتح للكتابة»** ودخّل باسورد الماك في الشباك اللي هيظهر. الحالة هتبقى **«قراءة وكتابة»** والهارد هيتفتح في Finder.
3. اشتغل عادي: انسخ وعدّل وامسح.
4. لما تخلص دوس **Eject** من التطبيق، **وبعدين بس** شيل الهارد.
   الأحسن تعمل Eject من التطبيق مش من Finder، لأنه بيستنى ntfs-3g يخلّص كتابة كل حاجة قبل ما يفصل الهارد.

## التحديث

```sh
cd ~/Macreader
git pull
./scripts/build_app.sh   # أو بـ SIGN_IDENTITY زي ما فوق
```
اقفل التطبيق من «اقفل MacReader» وافتحه تاني. لو بنيت من غير `SIGN_IDENTITY` هتحتاج تدي Full Disk Access تاني.

## لو حاجة مش شغّالة

| اللي ظهر | السبب | الحل |
|---|---|---|
| «MacReader مقدرش يقرا…» ومعاها `Operation not permitted` | التطبيق مش واخد Full Disk Access، أو اتبنى من جديد بتوقيع ad-hoc | شيله من Full Disk Access بـ **−** وضيفه تاني، واقفل التطبيق وافتحه |
| «درايفر FUSE مش شغّال…» ومعاها `ntfs-3g did not create a mount` | FUSE-T أو ntfs-3g بتاعه مش متسطّبين صح | عيد الخطوتين 2 و 3. الهارد بيفضل قراءة فقط ومبيتغيّرش فيه حاجة |
| «ويندوز مقفلش … صح» | الهارد في Fast Startup أو Hibernate، أو اتشال من غير Eject | شوف الجزء اللي تحت |
| «الهارد ده محتاج chkdsk على ويندوز» | الهارد اتشال وهو مفتوح للكتابة | وصّله على ويندوز واعمل `chkdsk X: /f`، وبعدين دوس «عملت chkdsk خلاص» |
| الهارد بيظهر باسم «NTFSTEST 1» بدل «NTFSTEST» | فيه فولدر قديم بنفس الاسم في `/Volumes` | مش بيأثر على حاجة. ولو عايز تشيله: اتأكد إن الهارد مش متركّب فيه، وبعدين `sudo rm -r "/Volumes/NAME"` |
| الهارد بيفصل لوحده وانت بتنسخ ملفات كبيرة | بعض الفلاشات الرخيصة بتعمل reset تحت الضغط | جرّب منفذ تاني أو هارد تاني. لو حصل وهو مفتوح للكتابة اعمله `chkdsk` على ويندوز |
| `Operation not permitted` في الـ Terminal جوه فولدر الهارد | قيود macOS على هاردات الشبكة (FUSE-T بيستخدم NFS) | فعّل **Network Volumes** للـ Terminal من System Settings ← Privacy & Security ← Files and Folders |

### لو الهارد مش راضي يتفتح للكتابة

غالباً ويندوز سايبه في حالة Fast Startup أو Hibernate. الحل:

- وصّله على ويندوز واعمل Shut down كامل: دوس **Shift** وانت بتختار Shut down.
- أو افتح Command Prompt كـ Administrator واكتب `chkdsk X: /f` (حط حرف الهارد مكان X).
- ولو عايز تحل المشكلة نهائي، اقفل Fast Startup من Control Panel ← Power Options ← Choose what the power buttons do.

## هيكل المشروع

```
Sources/MacReader/
  MacReaderApp.swift            # نقطة البداية + التحذير قبل قفل التطبيق
  Models/NTFSVolume.swift
  Services/DiskScanner.swift    # اكتشاف الهاردات (diskutil + getmntinfo)، بيقرا بس
  Services/DiskWatcher.swift    # DiskArbitration: لما هارد يتوصل أو يتشال
  Services/DependencyChecker.swift  # بيختار FUSE-T أو macFUSE ونسخة ntfs-3g المناسبة
  Services/Mounter.swift        # mount و unmount و eject بصلاحية أدمن، وفيه كل قواعد الأمان
  Services/VolumeStore.swift    # حالة التطبيق + متابعة الهاردات اللي اتشالت فجأة
  Services/Shell.swift
  Views/                        # الواجهة (SwiftUI)
Resources/Info.plist
scripts/build_app.sh
scripts/install_ntfs3g_fuse_t.sh  # بيبني ntfs-3g على FUSE-T
```

---

## English summary

MacReader is a SwiftUI menu-bar app (macOS 13+) that remounts external NTFS partitions read/write via **ntfs-3g**, preferably on **FUSE-T** (kext-less, local NFS: no Reduced Security, works on macOS 26/27), falling back to **macFUSE**.
Safety rules: read-only by default; never formats or repairs; mounts with `norecover` so hibernated or unclean volumes are refused; releases macOS's read-only mount and checks the NTFS boot-sector signature before mounting (BitLocker volumes are never touched, refusals restore the read-only mount); only reports success once a real mount exists; never force-unmounts; waits for ntfs-3g to exit before ejecting; remembers volumes that were unplugged while writable and requires a Windows `chkdsk` before writing to them again.
Admin steps run through `sudo -A` with a native password dialog, so the Full Disk Access granted to MacReader applies (osascript's `with administrator privileges` runs under `authtrampoline`, which TCC does not attribute to the app).
Setup (see the step-by-step section): `sudo mkdir -p /usr/local/include /usr/local/lib`, `brew trust --cask macos-fuse-t/cask/fuse-t && brew install --cask macos-fuse-t/cask/fuse-t`, then `./scripts/install_ntfs3g_fuse_t.sh`. Build with `./scripts/build_app.sh` (set `SIGN_IDENTITY` to a real certificate so Full Disk Access survives rebuilds). FUSE-T is free for personal use; commercial use needs a license from its authors.
**Always keep backups.** No NTFS driver outside Windows can guarantee zero risk.
