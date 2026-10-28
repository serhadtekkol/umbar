# Spike A2: Pano geçmişi ve macOS 27.0.1 pasteboard privacy

- **Kart:** #3 (spec §10 A2, §4.4 F4, AC-4.x). İzleyen işler: #16 (servis), #17 (UI)
- **Tarih:** 2026-10-26
- **Makineler:** Mac mini (macOS 27.0.1, 26A434) ve MacBook Air `Mac14,2` (macOS 27.0.1, 26A434, pilde)
- **SDK:** Xcode 27.0 (27A266a), MacOSX27.0.sdk
- **İmza:** **ad-hoc + Hardened Runtime**, umbar'ın `boringNotch.entitlements` dosyasıyla. Developer ID ile imzalanamadı: iki makinede de anahtar zinciri SSH oturumundan kilitli (`errSecInternalComponent`). Kartın kuralına göre sonuçlar **"ad-hoc"** etiketlidir ve D5 geldiğinde imzaya bağlı kısım (aşağıda S2) tekrar edilmeli.
- **Yazan:** Emrullah

## Sonuç

**GO (koşullu)**, #16 ve #17 için. Tahmin aşağıda.

1. **Stok macOS 27.0.1'de pano gizliliği uygulanmıyor.** Hiç görülmemiş bir bundle için bile `NSPasteboard.general.accessBehavior == .alwaysAllow`. Arka planda `string(forType:)` okuması sessizce ve 0 ms içinde döndü. Uyarı yok, TCC kaydı yok. İki makinede aynı sonuç.
2. **Uygulama mekanizması sistemde var ama bir bayrağın arkasında kapalı.** `EnablePasteboardPrivacyDeveloperPreview` (macOS 15.4'teki geliştirici önizlemesi) yalnızca probe sürecine argüman olarak verildiğinde davranış `.default` oluyor. Bu durumda arka plandaki okuma, kullanıcı cevap verene kadar okuyan thread'i **bloke ediyor** (20 sn'den fazla, yanıt yok). Karar AppKit'in `TrustedUIService` servisi üzerinden `kTCCServicePasteboard` ile veriliyor. Apple bunu ileride varsayılan yaparsa F4 bu modda çalışmak zorunda.
3. **Uyarıda "her zaman izin ver" seçeneği yok.** Sistemdeki uyarı metinleri yalnızca **"Allow Paste" / "Don't Allow Paste"** içeriyor. Kalıcı izin yalnızca *System Settings > Privacy & Security > Paste from Other Apps* içinde var. Uygulama bu listede ancak bir kez uyarı tetikledikten sonra görünüyor (SDK header'ı böyle diyor). Ayarı değiştirmek uygulamanın yeniden başlatılmasını gerektirebilir (`PASTEBOARD_ACCESS_QUIT_*` metinleri). Yani spec'teki A2 varsayımı ("uyarıda bir kez onaylanır") bu haliyle **yanlış**. Uygulama modunda doğru mekanizma uyarı değil, Ayarlar'daki "Allow" seçeneği.
4. **Uyarı vermeden yapılabilenler:** `changeCount`, `types` / `pasteboardItems[].types`, `detectedPatterns` / `detectedMetadata`. İki modda da uyarı çıkmadı, `accessBehavior` değişmedi. Concealed/transient işaretleri `types` içinde görünüyor, yani içerik okunmadan tespit edilip atlanabiliyor (AC-4.4).
5. **Boştaki maliyet:** 0,5 sn'lik polling **%0,036 CPU** (Mac mini) ve **%0,056 CPU** (Air, pilde), 60 sn ortalama. C1 sınırı (≤%1) için çok rahat bir pay.
6. **Spike'ın bulduğu hata:** Uygulama modunda `accessBehavior` getter'ı main thread dışından çağrılırsa süreç **çöküyor** (SIGABRT, `-[HIRunLoopSemaphore wait:]` assertion). Stok 27.0.1'de getter sabit bir değer döndüğü için bu hata hiçbir testte görünmez. ClipboardMonitor bu yüzden `@MainActor` yapıldı (bkz. Kanıt E6).

Koşullar (#16 için zorunlu tasarım kuralları):

- Arka plandaki monitör içeriği **yalnızca `accessBehavior == .alwaysAllow` iken** okur. Diğer her durumda okumaz, `.permissionRequired` yayınlar ve AC-4.8 durumunu gösterir. Böylece "tekrar eden uyarı" (kartın NO-GO koşulu) yapısal olarak oluşamaz.
- Pano erişimi main actor üzerinde yapılır (E6).
- Hassas veri işaretleri içerik okunmadan önce kontrol edilir (E4).
- Uygulama modu için tek seferlik kurulum akışı #17'de tasarlanmalı (aşağıda "Önerilen mekanizma" 4. madde). Bu akışın ürün kararı Furkan'da.

## Kabul kriterine cevaplar (kart #3)

| # | Soru | Cevap | Kanıt |
|---|---|---|---|
| 1 | Arka planda pano okuma (changeCount takibi) 27.0.1'de uyarı üretiyor mu? `accessBehavior` ve detect metotları gerçekte nasıl davranıyor? | **Stok:** hayır. `changeCount`, `types`, detect ve hatta içerik okuma sessiz, `accessBehavior` = `alwaysAllow`. **Uygulama modu:** `changeCount`, `types` ve detect sessiz. İçerik okuma uyarı akışını başlatıyor ve thread'i bloke ediyor. `accessBehavior` = `default`. | E1, E2, E3, E5 |
| 2 | Tek seferlik "her zaman izin ver" yeniden açılışta, reboot'ta ve yeni imzalı build'de kalıyor mu? | **Ölçülemedi, kullanıcı gerekiyor.** Uyarıda böyle bir seçenek zaten yok (E7). Kalıcı izin Ayarlar'dan veriliyor ve TCC'de designated requirement'a bağlı tutuluyor (tccd logu: `DR Identity for responsible=…`). Ad-hoc imzada DR cdhash'e bağlı olduğu için her yeni build'de izin kaybolur. Developer ID'de DR = bundle id + team id olduğundan kalması beklenir. Bu bir **çıkarım**, test edilmedi. Protokol aşağıda (S2). | E7, S2 |
| 3 | Concealed/transient tipler uyarı tetiklemeden tespit edilip atlanabiliyor mu (AC-4.4, BR-4.3)? | **Evet**, iki modda da. İşaret tipleri `types` içinde görünüyor ve monitör içeriği okumadan `.skippedSensitive` üretiyor. | E4 |
| 4 | Takibin boştaki CPU maliyeti C1'e göre nasıl? | %0,036 (mini) ve %0,056 (Air, pil), 0,5 sn aralık, 60 sn. C1 sınırı ≤%1. | E8 |

## Kanıt

Bütün ölçümler `Tools/PasteboardProbe` ile alındı. Bu, `open -n` ile başlatılan bir LSUIElement `.app`. Bu sayede TCC sorumlu süreci SSH değil probe'un kendisi oluyor. Bu tccd logunda doğrulandı: `AUTHREQ_ATTRIBUTION … requesting={identifier=com.umbar.spike.pbprobe …}` ve bir `responsible=sshd` zinciri yok. Probe, uygulamanın kullandığı `ClipboardMonitor.swift` dosyasını aynen derliyor. Çıktı JSON-lines formatında. Kullanıcı içeriği hiçbir zaman loga yazılmadı: yalnızca uzunluk ve probe'un kendi yazdığı token ile eşleşme kaydedildi.

"Uygulama modu", `-EnablePasteboardPrivacyDeveloperPreview YES` **süreç argümanıyla** (NSArgumentDomain) açıldı. Kalıcı bir `defaults write` yapılmadı, sistem ayarına dokunulmadı.

### E1: Stok davranış (iki makine)

```
behavior  → {"behavior":"alwaysAllow","changeCount":47}         (mini; Air: aynı, changeCount 17)
read      → {"elapsedMs":0,"isNil":false,"length":28,"matchesToken":true}   (mini)
read      → {"elapsedMs":0,"isNil":false,"length":26,"matchesToken":true}   (Air)
windowsDiff after-read → appeared: []
```

Bu sırada tccd'ye pano için hiçbir istek gitmedi. Log akışında görülen TCC servisleri: ListenEvent, ScreenCapture, AppleEvents vb. `kTCCServicePasteboard` yok.

### E2: Kapı bayrağı

`dyld_shared_cache_arm64e.01` içinde, CFPasteboard'un XPC anahtarlarının yanında şu dizgiler var: `EnablePasteboardPrivacyDeveloperPreview`, `com.apple.pboard.paste-general-notification`, `com.apple.pboard.create-verification-token`, `com.apple.pboard.get-paste-source`, `__shouldUseLegacyAccessBehavior.forceLegacyBehavior`. Servis adı `kTCCServicePasteboard`. Bayrak verilince:

```
behavior (preview) → {"behavior":"default"}     (mini ve Air)
```

### E3: Uygulama modunda içerik okuma

```
readTypes  → ["public.utf8-plain-text","NSStringPboardType"]      (uyarı yok)
readResult → {"returned":false,"elapsedMs":20112,"isNil":true}   (mini; Air: 9 sn sonra hâlâ bloke)
TrustedUIService[…] [com.apple.AppKit:TrustedUI] Pasteboard Read Access: TCC state is Ask (default).
WindowManager[…] Connection activated | (…) TrustedUIService (PasteboardProbe)
```

- Okuma, kullanıcı cevap verene kadar dönmüyor. Probe her seferinde `kill` ile kapatıldı, uyarıya cevap verilmedi. Sonrasında `accessBehavior` hâlâ `default` kaldı, yani cevapsız kapanan uyarı izin durumunu değiştirmiyor.
- **Uyarının ekranda gerçekten çizildiğini doğrulayamadım.** `CGWindowList` ne probe'a ne de `TrustedUIService`'e ait bir pencere gösterdi (güvenli UI listelenmiyor olabilir). Ekran görüntüsü almak Screen Recording izni gerektirdiği için denemedim. İki makinede de toplam 3 kez kısa süreli (9-24 sn) bir "“PasteboardProbe” is trying to access the pasteboard." uyarısı görünmüş olabilir.
- İlk denemede probe'da `com.apple.security.automation.apple-events` yoktu. tccd şunu yazdı: `Prompting policy for hardened runtime; service: kTCCServiceAppleEvents requires entitlement com.apple.security.automation.apple-events but it is missing`. Uyarı akışı sırasında bir Apple Event gönderiliyor. umbar'da bu entitlement var. Probe da artık aynı entitlement dosyasıyla imzalanıyor. Bu durumda hata kayboldu, bloke olma davranışı değişmedi. Not: umbar bu entitlement'ı kaybederse uyarı akışının davranışı test edilmeli.

### E4: Hassas tiplerin ve görüntülerin tespiti (iki makine, iki mod)

```
{"changeCount":70,"types":["public.utf8-plain-text","NSStringPboardType","org.nspasteboard.ConcealedType"],"behavior":"alwaysAllow"}
{"changeCount":71,"types":["public.utf8-plain-text","NSStringPboardType","org.nspasteboard.TransientType"]}
{"changeCount":72,"types":["public.tiff","NeXT TIFF v4.0 pasteboard type"]}
monitor (stok)   → captured(len=9) matchesToken:true | skippedSensitive(ConcealedType) | skippedSensitive(TransientType) | captured(len=9)
monitor (preview)→ permissionRequired(behavior=0) | skippedSensitive(ConcealedType) | skippedNonText
```

Uygulama modunda düz metin `permissionRequired` oldu. Okuma yapılmadı, uyarı çıkmadı, pencere değişmedi.

**Sınır:** İşaretler probe ile yazıldı (nspasteboard.org kuralındaki tiplerin aynısı). Gerçek bir parola yöneticisiyle (1Password, Bitwarden, Passwords.app) test edilmedi. Makinelerde 1Password/Bitwarden kurulu değil, Passwords.app'ten kopyalamak için UI tıklaması gerekiyor. Bu Habibe'nin keşif testine kalıyor.

### E5: Detect API'leri

```
detectedPatterns → [probableWebURL, links]                       (iki mod, uyarı yok, behavior değişmedi)
detectedMetadata(contentType) → NSCocoaErrorDomain 67587 / CFPasteboardErrorDomain -10   (dosya URL'i olmadığında beklenen)
```

`detectValues` header'a göre içeriği okuyor ("reading the contents if it finds a match"), bu yüzden test edilmedi ve geçmiş için kullanılmamalı. Detect API'leri pano geçmişi için yeterli değil: içerik vermiyorlar. Uygulama modunda yalnızca "panoda URL var" gibi ipuçları sağlayabilirler.

### E6: `accessBehavior` main thread dışında çöküyor (uygulama modu)

İlk ClipboardMonitor sürümü bir utility kuyruğunda poll yapıyordu. Uygulama modunda ilk değişiklikte süreç çöktü:

```
EXC_CRASH (SIGABRT), queue: umbar.clipboard-monitor
-[NSAssertionHandler handleFailureInMethod:…]
-[HIRunLoopSemaphore wait:].cold.1
-[HIRunLoopSemaphore wait]
AppKit …
ClipboardMonitor.tick()
```

Aynı çökme harness'te `snapshot()` nonisolated bir `async` fonksiyondan çağrıldığında da görüldü. Çözüm: `ClipboardMonitor` `@MainActor` ve timer `.main` kuyruğunda. **Regresyon kontrolü:** `monitor … onlyWhenAlwaysAllowed -EnablePasteboardPrivacyDeveloperPreview YES` artık çökmüyor ve beklenen olayları üretiyor (E4, ikinci satır; mini ve Air). Bu kontrol stok modda **bir şey ölçmez**, uygulama modu bayrağıyla koşulmalı.

### E7: Uyarı ve Ayarlar metinleri (sistemin kendi metinleri)

`TrustedUIService.xpc/…/TrustedUIService.loctable` (en):

- `PASTEBOARD_VERIFICATION_ALERT_MESSAGE_WITH_APP_NAME` → “%@” is trying to access the pasteboard.
- `PASTEBOARD_VERIFICATION_ALLOW_BUTTON_TITLE` → Allow Paste
- `PASTEBOARD_VERIFICATION_DENY_BUTTON_TITLE` → Don’t Allow Paste

`SecurityPrivacyExtension.appex/…/Localizable.loctable` (en), panel kimliği `privacy-pasteboard`, anchor `Privacy_Pasteboard`:

- `PASTEBOARD_ACCESS` → Paste from Other Apps
- `PASTEBOARD_ACCESS_SUMMARY` → Allow the applications below to access pasteboard contents from other applications at any time.
- `PASTEBOARD_ACCESS_QUIT_ALLOW_TITLE` → “%@” may not be able to access pasteboard contents from other applications until it is quit.

### E8: CPU (ClipboardMonitor, 0,5 sn aralık, 100 ms leeway, 60 sn, `getrusage`)

| Makine | Mod | CPU sn / 60 sn | CPU % |
|---|---|---|---|
| Mac mini | stok | 0,0219 | 0,036 |
| Mac mini | preview | 0,0217 | 0,036 |
| Air (pil) | stok | 0,0337 | 0,056 |
| Air (pil) | preview | 0,0333 | 0,055 |

Değerler süreç toplamıdır, harness'in kendi 1 sn'lik bekleme döngüsü de dahil. Yani üst sınırdır. Ölçüm sırasında `top` her 10 sn'de 0-2 idle wakeup gösterdi. Paylaşılan `pboard` daemon'unun `changeCount` başına maliyeti ölçülmedi (diğer istemcilerin gürültüsü ayrıştırılamadı).

### E9: SDK taraması (Xcode 27, MacOSX27.0.sdk)

`NSPasteboard.h` ve `NSPasteboardItem.h` dosyalarında pano gizliliğiyle ilgili ve 15.4'ten yeni **hiçbir API, entitlement ya da Info.plist anahtarı yok**. Var olanlar: `accessBehavior` (`default/ask/alwaysAllow/alwaysDeny`), `detectPatterns/Values/Metadata` (macOS 15.4). Swift overlay'de karşılıkları `detectedPatterns(for:)`, `detectedValues(for:)` ve `detectedMetadata(for:)`. İzin istemek için bir API yok, bir usage-description anahtarı da yok. CFPasteboard'da özel `set-is-excluded-from-history` mesajı var (Spotlight'ın pano geçmişi için olsa gerek). Bunun public bir karşılığı yok.

## Önerilen mekanizma (#16)

1. Main actor'da `DispatchSourceTimer` ile 0,5 sn aralık ve 100 ms leeway kullanılır. Yalnızca `changeCount` okunur. Değer opak kabul edilmeli, birer birer artacağı varsayılmamalı: gözlemde bir kopyalamada 47'den 67'ye atladı.
2. Değişiklik olduğunda önce `types` okunur ve sırayla şunlar uygulanır:
   - Hassas işaret varsa öğe atlanır, içerik **okunmaz**. İşaretler: `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType` ve eski tipler (`com.agilebits.onepassword` vb.). BR-4.3 için bu tipler diske asla yazılmaz.
   - Metin ya da görüntü tipi yoksa öğe atlanır.
   - `accessBehavior != .alwaysAllow` ise `.permissionRequired` üretilir.
   - Bunların hiçbiri değilse okunur. Okumadan sonra `changeCount` tekrar kontrol edilir; değiştiyse okunan değer atılır.
3. AC-4.5 (hariç tutulan uygulamalar): kaynak uygulama için bir public API yok. Öneri: varsa `org.nspasteboard.source` tipi (bundle id) kullanılır, yoksa değişiklik anındaki `NSWorkspace.frontmostApplication` (sezgisel bir yöntem, en fazla 0,5 sn gecikmeli). Bu spike'ta test edilmedi.
   *Uygulanan (güvenlik incelemesi M3):* yalnızca yoklama anındaki ön uygulama yetmez (parola yöneticisinde ⌘C, 0,5 sn içinde ⌘Tab kaçar). `ClipboardMonitor`, `NSWorkspace.didActivateApplicationNotification` ile son yoklamadan bu yana öne gelen her uygulamayı tutar; listedekilerden biri o aralıkta önde olduysa içerik okunmaz. `org.nspasteboard.source` yalnızca erişim "her zaman izinli" iken okunur (bir içerik okuması) ve yalnızca atlama sebebi ekler. Öne hiç gelmeyen menü çubuğu panelleri (1Password Quick Access) yalnızca bu işaretle ya da ConcealedType ile yakalanır.
4. **Uygulama modu için kurulum akışı (#17, ürün kararı):**
   1. Widget "Pano geçmişi için izin gerekli" durumunu gösterir (AC-4.8).
   2. Kullanıcı "İzin ver" düğmesine basar. Uygulama aktifken tek ve bilinçli bir okuma yapılır. Sistem uyarısı çıkar, kullanıcı "Allow Paste" seçer. Uygulama bundan sonra Ayarlar listesinde görünür.
   3. `x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard` açılır (anchor sistem plist'inden alındı, URL'in açtığı panel doğrulanmadı). Kullanıcı "Allow" seçer.
   4. Gerekirse uygulama yeniden başlatılır.

   Bu akış bugün stok 27.0.1'de hiç devreye girmez, çünkü `alwaysAllow` zaten geliyor. Kod yine de hazır olmalı.
5. Pano'ya geri yazmak (AC-4.2) hiçbir modda kısıtlı değil.

Reddedilen alternatifler:
- **Arka planda okuyup uyarıyı kabullenmek.** Her kopyalamada uyarı çıkar ve okuyan thread kilitlenir. Kartın NO-GO tanımına birebir uyuyor.
- **Yalnızca detect API'leri.** İçerik vermiyorlar, geçmiş tutulamaz.
- **Private CFPasteboard ya da `pboard` XPC.** Uygulama modunu aşmaya çalışmak hem kırılgan hem de gizlilik açısından savunulamaz.
- **Accessibility ile ⌘C yakalamak.** Ek izin gerektirir ve diğer kopyalama yollarını kaçırır.

## Tahmin (F4, #16 + #17)

Varsayımlar: Settings altyapısı (#8) hazır, K9 = metin + görüntü, disk kalıcılığı basit (JSON/plist + boyut sınırı). Muhittin'in incelemesi dahil değil.

| | İyimser | En olası | Kötümser |
|---|---|---|---|
| #16 servis (monitör, depolama, limitler, dedupe, hariç tutma, temizle, sabitleme, testler) | 2 g | 3 g | 5 g |
| #17 UI (liste, geri yükleme, sabitleme, temizle onayı, izin durumu + kurulum akışı, hariç tutulan uygulamalar ayarı) | 2 g | 3 g | 4 g |
| **Toplam** | **4 g** | **6 g** | **9 g** |

Kötümser senaryonun ana sebepleri: hariç tutma için kaynak uygulamanın güvenilir tespiti, görüntü boyutu ve disk sınırları, ve uygulama modunun D5 imzasıyla tekrar test edilmesi.

## Kullanıcı gereken adımlar (S1-S3)

Ben tıklayamadım. Bu adımlar kullanıcı ya da Habibe tarafından yapılmalı:

- **S1: Uyarının ekranda görünümü.** Harness'i uygulama modunda koşun: `open -n PasteboardProbe.app --args read /tmp/r.jsonl -EnablePasteboardPrivacyDeveloperPreview YES`. Uyarının metnini ve hangi ekranda/konumda çıktığını doğrulayın. "Allow Paste" seçildiğinde `readResult.returned` true olmalı. Ardından `accessBehavior` değerinin `ask` olup olmadığını (`behavior` modu) ve uygulamanın *Paste from Other Apps* listesine düşüp düşmediğini kontrol edin.
- **S2: Kalıcılık** (D5 Developer ID imzası ile, anahtar zinciri açık bir GUI oturumunda):
  1. Ayarlar'da "Allow" seçin.
  2. Uygulamayı kapatıp açın ve `behavior` değerinin `alwaysAllow` kaldığını kontrol edin.
  3. Reboot sonrası aynı kontrolü yapın.
  4. Aynı kimlikle **yeniden build** alıp aynı kontrolü yapın.
  5. Ad-hoc build ile 4. adımı tekrarlayın (beklenen: izin kaybolur).

  Temizlik için `tccutil reset Pasteboard <bundle id>` (servis adı `kTCCServicePasteboard` olduğundan "Pasteboard" beklenir, doğrulanmadı).
- **S3: Gerçek parola yöneticisi.** Passwords.app ya da Keychain Access'ten bir parola kopyalayın. Monitör `skippedSensitive` üretmeli. Harness: `monitor /tmp/m.jsonl 20`.

## Yeniden üretme

```sh
Tools/PasteboardProbe/build.sh <out-dir> ["Developer ID Application: …"]
P=<out-dir>/PasteboardProbe.app
open -n -W $P --args selftest /tmp/st.jsonl            # 19 deterministik kontrol, genel panoya dokunmaz
open -n -W $P --args behavior /tmp/b.jsonl [-EnablePasteboardPrivacyDeveloperPreview YES]
open -n    $P --args types    /tmp/t.jsonl 8            # sonra: write plain|concealed|transient|image <token>
open -n    $P --args monitor  /tmp/m.jsonl 8 onlyWhenAlwaysAllowed <token> [-Enable… YES]
open -n -W $P --args cpu      /tmp/c.jsonl 60 500 [-Enable… YES]
```

Probe genel panoya yazar. Testten önce panodaki metni yedekleyin ve test bittiğinde geri yükleyin. Bu spike'ta Mac mini'deki 5 baytlık metin geri yüklendi. Air'deki pano boştu ve test sonunda yeniden boşaltıldı.

## Bu branch'teki kod

- `boringNotch/private/Clipboard/ClipboardMonitor.swift`: monitör (main actor, okuma politikası, hassas işaretler).
- `boringNotch/private/Clipboard/ClipboardMonitorController.swift`: bayrağı izler, monitörü açar ve kapatır. İçerik tutmaz.
- `boringNotch/private/Clipboard/ClipboardDefaults.swift`: `clipboardMonitorEnabled` (varsayılan `false`).
- `boringNotch/boringNotchApp.swift`: açılışta `ClipboardMonitorController.shared.activate()`. Bayrak kapalıyken hiçbir şey yapmaz.
- `Tools/PasteboardProbe/`: harness (app target'ında değil).

Dosyalar `private/` altında, çünkü app target'ında file-system-synchronized olan tek grup `boringNotch/private`. `managers/` klasik bir grup ve oraya eklenen dosyalar derlenmiyor. Kardeş branch'ler (caffeinate, eye-break) de aynı yolu kullanıyor. `project.pbxproj` düzenlenmedi.
