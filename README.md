# MacReader

تطبيق صغير في شريط القوايم (Menu Bar) على الماك، بيخلّيك **تقرا وتكتب** على هارد خارجي متفرمت **NTFS** (الفورمات بتاع ويندوز).
الماك لوحده بيقرا NTFS بس ومبيكتبش عليه.

> A small macOS menu-bar app that makes external **NTFS** drives writable, using macFUSE + ntfs-3g, with data safety as the first priority. English summary at the bottom.

---

## بيشتغل إزاي؟

MacReader **مبيكتبش على الهارد بنفسه**. الكتابة بتعدّي من [ntfs-3g](https://github.com/tuxera/ntfs-3g)، وده درايفر NTFS مستخدم في لينكس من سنين،
وشغّال على الماك عن طريق [macFUSE](https://osxfuse.github.io). التطبيق بيعمل كده:

1. يكتشف أي هارد NTFS أول ما يتوصل.
2. لما تدوس **«افتح للكتابة»**، يطلب باسورد الماك، ويفك الـ mount اللي قراءة فقط، ويركّب الهارد تاني بـ ntfs-3g للقراءة والكتابة.
3. لما تدوس **Eject**، يحفظ كل حاجة ويفصل الهارد بأمان.

## حماية الداتا 🛡️

- **قراءة فقط هي الأساس.** مفيش كتابة غير لما تدوس الزرار بنفسك. خاصية الفتح التلقائي مقفولة من الأول.
- **مفيش إصلاح ولا فرمتة خالص.** التطبيق مفيهوش أي أمر `format` أو `ntfsfix` أو `chkdsk`، ومبيمسحش ملف الـ Hibernate بتاع ويندوز.
- **بيرفض الهاردات اللي مقفلتش صح.** الـ mount بيتعمل بـ `-o norecover`. لو ويندوز سايب الهارد في Fast Startup أو Hibernate، أو الهارد اتشال من غير Eject، ntfs-3g بيرفض يفتحه للكتابة والتطبيق بيرجّعه قراءة فقط.
- **بيتأكد إنه NTFS بجد.** قبل أي mount بيقرا توقيع الـ boot sector. لو مش `NTFS` (زي BitLocker)، مبيلمسش الهارد.
- **مفيش Eject بالعافية.** الفصل بيتعمل من غير `force`. لو فيه ملف مفتوح، الفصل بيفشل والتطبيق يقولك أنهي برنامج فاتحه.
- **بيستنى الكتابة تخلص.** قبل ما يفصل الهارد بيستنى ntfs-3g يخلّص كتابة كل الداتا ويقفل، وبعدين بس يعمل Eject.
- **بيفتكر لو الهارد اتشال فجأة.** لو الهارد اتشال وهو مفتوح للكتابة، المرة الجاية مش هيتفتح للكتابة لحد ما تعمله `chkdsk` على ويندوز.
- **تحذير قبل ما تقفل التطبيق** لو فيه هارد لسه مفتوح للكتابة.

> ⚠️ **بصراحة:** مفيش أداة تضمن 100%. خلّي عندك نسخة احتياطية من الحاجات المهمة، وجرّب التطبيق الأول على هارد مفيهوش حاجة مهمة.

## المتطلبات

- macOS 13 (Ventura) أو أحدث.
- [Homebrew](https://brew.sh).
- **macFUSE**:
  ```sh
  brew install --cask macfuse
  ```
  بعد التسطيب افتح **System Settings ← Privacy & Security**، ودوس **Allow** للـ extension، وبعدين اعمل Restart.
  على أجهزة **Apple Silicon** (M1/M2/M3/…) ممكن يطلب منك تفعّل **Reduced Security** من Recovery Mode قبل كده، وده بيتعمل مرة واحدة بس.
- **ntfs-3g**:
  ```sh
  brew tap gromgit/homebrew-fuse
  brew install ntfs-3g-mac
  ```

لو حاجة منهم ناقصة، التطبيق هيوريك الخطوات دي وفيه زرار تنسخ بيه الأمر.

## البناء والتشغيل

محتاج Xcode أو Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/omaralam2/Macreader.git
cd Macreader
./scripts/build_app.sh
open build/MacReader.app
# أو انقله لمجلد التطبيقات:
cp -R build/MacReader.app /Applications/
```

هيظهر رمز هارد 🖴 في شريط القوايم فوق.

## الاستخدام

1. وصّل الهارد. هيظهر في القائمة وجنبه **«قراءة فقط»**.
2. دوس **«افتح للكتابة»** ودخّل باسورد الماك. الحالة هتبقى **«قراءة وكتابة»** والهارد هيتفتح في Finder.
3. اشتغل عادي: انسخ وعدّل وامسح.
4. لما تخلص دوس **Eject** من التطبيق، أو Eject من Finder، **وبعدين بس** شيل الهارد.

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
  Services/DependencyChecker.swift
  Services/Mounter.swift        # mount و unmount و eject بصلاحية أدمن، وفيه كل قواعد الأمان
  Services/VolumeStore.swift    # حالة التطبيق + متابعة الهاردات اللي اتشالت فجأة
  Services/Shell.swift
  Views/                        # الواجهة (SwiftUI)
Resources/Info.plist
scripts/build_app.sh
```

---

## English summary

MacReader is a SwiftUI menu-bar app (macOS 13+) that remounts external NTFS partitions read/write via **ntfs-3g + macFUSE**.
Safety rules: read-only by default; never formats or repairs; mounts with `norecover` so hibernated or unclean volumes are refused; checks the NTFS boot-sector signature before mounting (BitLocker volumes are never touched); never force-unmounts; waits for ntfs-3g to exit before ejecting; remembers volumes that were unplugged while writable and requires a Windows `chkdsk` before writing to them again.
Build with `./scripts/build_app.sh`. Requires `brew install --cask macfuse` and `brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac`.
**Always keep backups.** No NTFS driver outside Windows can guarantee zero risk.
